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
import androidx.compose.material3.FilterChip
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
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
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
import io.github.haige120.cloudreader.ui.ConnectionStatus
import io.github.haige120.cloudreader.ui.SyncDestinationCard
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
    val search by app.preferences.observe("ai.webSearch", "false").collectAsState(initial = "false")
    val assistant: AssistantViewModel = viewModel(factory = AssistantViewModel.factory(app))
    val state by assistant.state.collectAsStateWithLifecycle()
    val chats = state.conversations
    val active = state.activeConversation
    val readerContext = state.pendingReaderContext
    val scope = rememberCoroutineScope()
    val androidContext = LocalContext.current

    LaunchedEffect(context) {
        if (context != null) {
            assistant.prepareReaderContext(AssistantContext(context.book, context.selectedText, context.bookText))
            onContextConsumed()
        }
    }
    LaunchedEffect(state.error) { state.error?.let(onMessage) }

    io.github.haige120.cloudreader.ui.AssistantContent(
        keyboardSend = true, chats = chats, active = active, draft = state.draft, busy = state.busy,
        includeContext = state.includeContext,
        contextPreview = if (readerContext != null) readerContext.selectedText ?: readerContext.boundedBookText ?: readerContext.book?.title
            else active?.selectedText ?: active?.bookContext ?: active?.bookTitle,
        error = state.error, profileLabel = "$aiName · ${model.ifBlank { "Set up an AI model in Settings" }}",
        onDraft = assistant::updateDraft, onSelect = assistant::selectConversation, onNew = {
            scope.launch {
                val source = readerContext ?: active?.bookID?.let { id -> app.database.libraryDao().book(id)?.toDomain()?.let { AssistantContext(it) } }
                assistant.newBookConversation(source)
            }
        },
        onConsent = assistant::setContextConsent,
        onSend = {
            scope.launch {
                val sourceBook = readerContext?.book ?: active?.bookID?.let { id -> app.database.libraryDao().book(id)?.toDomain() }
                val selected = if (readerContext != null) readerContext.selectedText else active?.selectedText
                val bounded = if (state.includeContext && sourceBook != null) {
                    (if (readerContext != null) readerContext.boundedBookText else active?.bookContext)
                        ?: boundedBookText(androidContext, app, sourceBook)
                } else null
                assistant.send(AIProfile(aiName, protocol, endpoint, model, search.toBoolean()), AssistantContext(sourceBook, selected, bounded))
            }
        },
        onCancel = assistant::cancelRequest,
        onRetry = { assistant.retry(AIProfile(aiName, protocol, endpoint, model, search.toBoolean())) },
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
    settingsModel: SettingsViewModel? = null,
) {
    val scope = rememberCoroutineScope()
    val model: SettingsViewModel = settingsModel ?: viewModel(factory = SettingsViewModel.factory(app))
    val state by model.state.collectAsStateWithLifecycle()
    val selected = state.selectedProviders
    var showGoogleSetup by remember { mutableStateOf(false) }
    var showAdvancedGoogle by remember { mutableStateOf(false) }
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
        Text("Library connection details stay on this device. Sync copies books, progress, favorites, deletions, and saved conversations.", style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
        SectionTitle("Reading")
        val translate by app.preferences.observe("reader.translateWords", "false").collectAsState(initial = "false")
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text("Translate selected English words", Modifier.weight(1f))
            Switch(translate.toBoolean(), { scope.launch { app.preferences.setBool("reader.translateWords", it) } },
                modifier = Modifier.semantics { contentDescription = "Translate selected English words" })
        }
        if (translate.toBoolean()) {
            val systemLanguage = androidx.compose.ui.platform.LocalConfiguration.current.locales[0].toLanguageTag()
            val target by app.preferences.observe("reader.translationTarget", systemLanguage).collectAsState(initial = systemLanguage)
            var showLanguages by remember { mutableStateOf(false) }
            TextButton(onClick = { showLanguages = true }) { Text("Translation language · " + java.util.Locale.forLanguageTag(target).displayName) }
            if (showLanguages) ModelPicker(
                title = "Translation language", searchLabel = "Search languages",
                load = { WordTranslation.targets(activity) },
                label = { java.util.Locale.forLanguageTag(it).displayName },
                empty = "No matching installed languages. Check your device’s translation settings.",
                choose = { scope.launch { app.preferences.set("reader.translationTarget", it) }; showLanguages = false },
                dismiss = { showLanguages = false }
            )
        }
        SectionTitle("App appearance")
        val appearance by app.preferences.observe("app.appearance", "system").collectAsState(initial = "system")
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            listOf("system", "light", "dark").forEach { choice ->
                FilterChip(appearance == choice, { scope.launch { app.preferences.set("app.appearance", choice) } },
                    label = { Text(choice.replaceFirstChar(Char::uppercase)) })
            }
        }
        SectionTitle("Sync destinations")
        Text("Connect Google Drive, choose your account and allow backup access. No client ID or secret is needed for the standard connection.", style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
        if (state.googleUseCustomCredentials) {
            Text("This device is using a custom Google project. Your saved credentials are retained.", style = MaterialTheme.typography.bodyMedium)
            TextButton(onClick = { model.setCustomGoogleCredentials(false) }, enabled = !googleConnection.busy && !state.googleCredentialsSaving) { Text("Use standard Google connection") }
        }
        providerIDs.forEach { id ->
            val folderReady = id != "filesFolder" || state.folderName.isNotBlank()
            val providerReady = folderReady && (id != "googleDrive" || !state.googleCredentialsSaving)
            SyncDestinationCard(
                title = providerNames.getValue(id),
                subtitle = if (id == "filesFolder" && !folderReady) "Choose a folder to enable sync" else if (id in selected) "Selected for foreground sync" else "Not selected",
                selected = id in selected, enabled = providerReady,
                onSelected = { model.selectProvider(id, it) },
            ) {
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
                if (status != null) ConnectionStatus(
                    status, needsAttention = googleConnection.failed,
                    onSetup = if (googleConnection.requiresSetup) ({ showGoogleSetup = true }) else null,
                )
            }
        }
        TextButton(onClick = { showAdvancedGoogle = !showAdvancedGoogle }) { Text(if (showAdvancedGoogle) "Hide advanced Google settings" else "Advanced Google settings (optional)") }
        if (showAdvancedGoogle) {
        SectionTitle("Advanced Google settings")
        Row(verticalAlignment = Alignment.CenterVertically) {
            Switch(modifier = Modifier.semantics { contentDescription = "Use custom Google credentials" }, checked = state.googleUseCustomCredentials, onCheckedChange = model::setCustomGoogleCredentials, enabled = !googleConnection.busy && !state.googleCredentialsSaving)
            Text("Use my own Google Cloud project", modifier = Modifier.padding(start = 12.dp))
        }
        TextButton(onClick = { showGoogleSetup = true }) { Text("Google connection help and registration") }
        if (state.googleUseCustomCredentials) {
        Text("Android needs two OAuth clients in the same Google Cloud project: an Android registration for this installed app, and a Web application client for the ID and secret below. A Web ID and secret alone cannot register the app.", style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
        TextButton(onClick = { showGoogleSetup = true }) { Text("Google setup and Android registration") }
        Field("Google OAuth client ID (Web application)", state.googleClientId, { model.update(SettingsField.GOOGLE_CLIENT_ID, it) }, placeholder = "…apps.googleusercontent.com")
        SecretField("Google OAuth client secret", state.googleClientSecret, { model.update(SettingsField.GOOGLE_CLIENT_SECRET, it) }, "Leave blank to keep the saved secret for this ID")
        if (state.googleSecretSaved && state.googleClientId.trim() == state.googleSavedClientId.trim()) {
            Text("A secret is saved on this device for this client ID. The empty field does not erase it.", style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        Button(onClick = { model.saveGoogleCredentials() }, enabled = !googleConnection.busy && !state.googleCredentialsSaving) { Text(if (state.googleCredentialsSaving) "Saving…" else "Save Google app credentials") }
        Text("Save first, then tap Connect above. Changing credentials requires reconnecting. Turn off custom setup to use standard Google connection without erasing these credentials.", style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        }

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
        Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            listOf("openAIResponses", "openAIChatCompletions", "anthropicMessages").forEach { choice ->
                FilterChip(selected = state.aiProtocol == choice, onClick = { model.update(SettingsField.AI_PROTOCOL, choice) }, label = {
                    Text(when (choice) { "openAIResponses" -> "Responses"; "openAIChatCompletions" -> "Chat Completions"; else -> "Anthropic" })
                })
            }
        }
        Field("Model", state.aiModel, { model.update(SettingsField.AI_MODEL, it) }, placeholder = "Model ID")
        Field("Custom HTTPS endpoint (optional)", state.aiEndpoint, { model.update(SettingsField.AI_ENDPOINT, it) }, placeholder = "Leave blank for the provider default")
        SecretField("API key", state.aiKey, { model.update(SettingsField.AI_KEY, it) })
        var browse by remember { mutableStateOf(false) }
        TextButton(onClick = { browse = true }) { Text("Browse models") }
        if (browse) ModelPicker(
            load = { app.ai.models(AIProfile(protocol = state.aiProtocol, endpoint = state.aiEndpoint.trim()), state.aiKey) },
            choose = { model.update(SettingsField.AI_MODEL, it); browse = false }, dismiss = { browse = false }
        )
        val search by app.preferences.observe("ai.webSearch", "false").collectAsState(initial = "false")
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text("Allow provider web search", Modifier.weight(1f))
            Switch(search.toBoolean(), { scope.launch { app.preferences.setBool("ai.webSearch", it) } },
                modifier = Modifier.semantics { contentDescription = "Allow provider web search" })
        }
        val fallback by app.preferences.observe("ai.offlineFallback", "true").collectAsState(initial = "true")
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text("Use installed Gemini Nano when offline", Modifier.weight(1f))
            Switch(fallback.toBoolean(), { scope.launch { app.preferences.setBool("ai.offlineFallback", it) } },
                modifier = Modifier.semantics { contentDescription = "Use installed Gemini Nano when offline" })
        }
        TextButton(onClick = { model.removeAiKey() }) { Text("Remove saved API key") }
        Button(onClick = { model.saveAi() }) { Text("Save AI profile") }
        Text("Your password manager can carry a saved copy of this AI profile and its API key to another Android device.")
        Row {
            TextButton(onClick = { scope.launch { transferAiSettings(activity, model, save = true, onMessage) } }) { Text("Save copy") }
            TextButton(onClick = { scope.launch { transferAiSettings(activity, model, save = false, onMessage) } }) { Text("Restore copy") }
        }
        Text("Book chats start with context enabled. Turn it off before sending to keep book details out of the request. Offline answers require a supported device with Gemini Nano available.", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.secondary)
        Spacer(Modifier.height(18.dp))
    }
    if (showGoogleSetup) {
        AlertDialog(
            onDismissRequest = { showGoogleSetup = false },
            title = { Text("Google Drive setup") },
            text = {
                androidx.compose.foundation.text.selection.SelectionContainer {
                    Column(Modifier.verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                        Text(if (state.googleUseCustomCredentials) "Custom setup: open the project that owns your Web client ID, enable the Google Drive API, and create an Android OAuth client with this registration." else "You do not need your own client ID or secret. If Google does not recognize this build, CloudReader's maintainer must register its package and signing certificate in the app's Google Cloud project. Send the maintainer these details:")
                        Text(googleRegistration, style = MaterialTheme.typography.bodyMedium)
                        TextButton(onClick = {
                            val clipboard = activity.getSystemService(android.content.Context.CLIPBOARD_SERVICE) as android.content.ClipboardManager
                            clipboard.setPrimaryClip(android.content.ClipData.newPlainText("CloudReader Android OAuth registration", googleRegistration))
                        }) { Text("Copy package and SHA-1") }
                        if (state.googleUseCustomCredentials) {
                        Text("3. In that same project, create a Web application OAuth client. Save its ID and secret in CloudReader. Android client IDs have no secret.")
                        Text("4. Configure the Google Auth consent audience. If the project is in Testing, add your Google account as a test user. Return here and tap Connect.")
                        Text("UNREGISTERED_ON_API_CONSOLE means the Android package/certificate is not registered for this project. Retrying or replacing the Web secret alone does not fix that. A different APK signing key needs its own matching registration; never uninstall or clear your library to work around it.")
                        Text("Windows and Linux instead need an OAuth client of type Desktop app. Do not reuse the Android Web client there.")
                        TextButton(onClick = { activity.startActivity(Intent(Intent.ACTION_VIEW, android.net.Uri.parse("https://console.cloud.google.com/apis/credentials"))) }) { Text("Open Google Cloud credentials") }
                        } else {
                            Text("A Web client secret cannot replace Android registration. Keep your library intact: do not uninstall or clear data to work around this error. Contact the app maintainer, then retry Connect after the registration is corrected.")
                        }
                    }
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

@Composable
private fun ModelPicker(load: suspend () -> List<String>, choose: (String) -> Unit, dismiss: () -> Unit,
    title: String = "Choose a model", searchLabel: String = "Search models", label: (String) -> String = { it }, empty: String = "No matching models.") {
    var models by remember { mutableStateOf<List<String>?>(null) }
    var error by remember { mutableStateOf<String?>(null) }
    var query by remember { mutableStateOf("") }
    LaunchedEffect(Unit) {
        try { models = load() }
        catch (cancelled: kotlinx.coroutines.CancellationException) { throw cancelled }
        catch (failure: Exception) { error = failure.localizedMessage ?: "Could not load models." }
    }
    AlertDialog(onDismissRequest = dismiss, title = { Text(title) }, text = {
        Column {
            OutlinedTextField(query, { query = it }, label = { Text(searchLabel) }, singleLine = true)
            val filtered = models?.filter { it.contains(query, ignoreCase = true) || label(it).contains(query, ignoreCase = true) }
            when {
                error != null -> Text(error.orEmpty())
                filtered == null -> CircularProgressIndicator()
                filtered.isEmpty() -> Text(empty)
                else -> LazyColumn(Modifier.fillMaxWidth().height(280.dp)) {
                    items(filtered, key = { it }) { id -> TextButton(onClick = { choose(id) }) { Text(label(id)) } }
                }
            }
        }
    }, confirmButton = { TextButton(onClick = dismiss) { Text("Close") } })
}
