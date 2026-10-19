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
import androidx.compose.runtime.saveable.rememberSaveable
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
import io.github.haige120.cloudreader.data.ChatMessage
import io.github.haige120.cloudreader.data.ChatRecord
import io.github.haige120.cloudreader.data.ConversationRow
import io.github.haige120.cloudreader.data.nowFoundationSeconds
import io.github.haige120.cloudreader.sync.OAuthConnector
import io.github.haige120.cloudreader.sync.SyncCodec
import java.io.File
import java.util.UUID
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

@Composable
fun AssistantScreen(app: CloudReaderApp, context: ReaderContext?, onContextConsumed: () -> Unit, onMessage: (String) -> Unit) {
    val rows by app.library.conversations.collectAsState(initial = emptyList())
    val chats = remember(rows) { rows.mapNotNull { row -> runCatching { SyncCodec.chatFromJson(row.wireJson) }.getOrNull() }.sortedByDescending { it.modifiedAt } }
    val aiName by app.preferences.observe("ai.name", "My AI").collectAsState(initial = "My AI")
    val protocol by app.preferences.observe("ai.protocol", "openAIResponses").collectAsState(initial = "openAIResponses")
    val endpoint by app.preferences.observe("ai.endpoint", "").collectAsState(initial = "")
    val model by app.preferences.observe("ai.model", "").collectAsState(initial = "")
    var active by remember { mutableStateOf<ChatRecord?>(null) }
    var draft by rememberSaveable { mutableStateOf("") }
    var includeContext by rememberSaveable { mutableStateOf(false) }
    var busy by rememberSaveable { mutableStateOf(false) }
    var confirmDelete by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()
    val androidContext = LocalContext.current

    LaunchedEffect(context?.book?.id, context?.selectedText) {
        if (context != null) {
            active = ChatRecord(
                id = UUID.randomUUID().toString().uppercase(), title = "New conversation", messages = emptyList(),
                bookID = context.book?.id, bookTitle = context.book?.title, bookDescription = context.book?.briefDescription,
                selectedText = context.selectedText, includeBookContext = false,
                createdAt = nowFoundationSeconds(), modifiedAt = nowFoundationSeconds(),
            )
            includeContext = false
            onContextConsumed()
        }
    }

    fun selectChat(chat: ChatRecord) {
        active = chat
        includeContext = chat.includeBookContext
    }

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
                        if (includeContext && !chat.selectedText.isNullOrBlank()) append("\n\nSelected passage:\n${chat.selectedText}")
                        if (includeContext && !chat.bookContext.isNullOrBlank()) append("\n\nBook excerpt:\n${chat.bookContext}")
                    }
                    if (prepared.isNotBlank()) androidContext.startActivity(Intent.createChooser(Intent(Intent.ACTION_SEND).setType("text/plain").putExtra(Intent.EXTRA_TEXT, prepared), "Share prompt"))
                }
            }) { Icon(Icons.Filled.Share, contentDescription = "Share prepared prompt") }
            IconButton(onClick = { active = null; draft = "" }) { Icon(Icons.Filled.Add, contentDescription = "New conversation") }
            if (active != null) IconButton(onClick = { confirmDelete = true }) {
                Icon(Icons.Filled.DeleteOutline, contentDescription = "Delete conversation")
            }
        }

        if (chats.isNotEmpty()) {
            Row(Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                chats.forEach { chat ->
                    val selected = active?.id == chat.id
                    TextButton(onClick = { selectChat(chat) }, modifier = Modifier.background(if (selected) Color(0xFFE4EADF) else Color(0xFFEFE9DD), RoundedCornerShape(18.dp))) {
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
                Text(if (context?.selectedText != null) "Ask about this passage" else "What are you reading today?", fontFamily = FontFamily.Serif, fontSize = 21.sp, textAlign = TextAlign.Center)
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
                if (busy) item { CircularProgressIndicator(modifier = Modifier.padding(14.dp)) }
            }
        }

        val hasReaderContext = context?.book != null || active?.selectedText != null || active?.bookID != null
        if (hasReaderContext) {
            Row(Modifier.fillMaxWidth().clickable { includeContext = !includeContext }.padding(vertical = 5.dp), verticalAlignment = Alignment.CenterVertically) {
                Checkbox(checked = includeContext, onCheckedChange = { includeContext = it })
                Column {
                    Text("Include selected passage or book text", style = MaterialTheme.typography.labelLarge)
                    Text("Only included after you send this question · up to 18,000 characters", style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.secondary)
                }
            }
        }
        Row(Modifier.fillMaxWidth().padding(bottom = 8.dp), verticalAlignment = Alignment.Bottom) {
            OutlinedTextField(
                value = draft, onValueChange = { draft = it }, modifier = Modifier.weight(1f),
                placeholder = { Text("Ask a question") }, minLines = 1, maxLines = 5, shape = RoundedCornerShape(18.dp), enabled = !busy,
            )
            IconButton(
                enabled = !busy && draft.isNotBlank(),
                onClick = {
                    val question = draft.trim()
                    if (question.isBlank()) return@IconButton
                    draft = ""
                    busy = true
                    scope.launch {
                        runCatching {
                            val old = active
                            val now = nowFoundationSeconds()
                            val chatID = old?.id ?: UUID.randomUUID().toString().uppercase()
                            val sourceBook = context?.book ?: old?.bookID?.let { id -> app.database.libraryDao().book(id) }
                            val selected = if (includeContext) context?.selectedText ?: old?.selectedText else null
                            val fullText = if (includeContext && selected.isNullOrBlank() && sourceBook != null) boundedBookText(androidContext, app, sourceBook) else null
                            val userMessage = ChatMessage(UUID.randomUUID().toString().uppercase(), "user", question, now)
                            val withUser = (old ?: ChatRecord(id = chatID, title = "New conversation", messages = emptyList(), createdAt = now, modifiedAt = now)).copy(
                                messages = (old?.messages.orEmpty() + userMessage),
                                bookID = sourceBook?.id ?: old?.bookID,
                                bookTitle = sourceBook?.title ?: old?.bookTitle,
                                bookDescription = sourceBook?.briefDescription ?: old?.bookDescription,
                                selectedText = selected,
                                bookContext = fullText,
                                contextDescription = if (selected != null) "Selected passage" else if (fullText != null) "Bounded book excerpt" else null,
                                includeBookContext = includeContext,
                                createdAt = old?.createdAt ?: now,
                                modifiedAt = now,
                            )
                            active = withUser
                            app.library.saveChat(withUser)
                            val answer = app.ai.ask(
                                AIProfile(aiName, protocol, endpoint, model), withUser.messages.takeLast(40),
                                bookTitle = withUser.bookTitle,
                                selectedText = if (includeContext) withUser.selectedText else null,
                                bookContext = if (includeContext) withUser.bookContext else null,
                            )
                            val assistant = ChatMessage(UUID.randomUUID().toString().uppercase(), "assistant", answer, nowFoundationSeconds())
                            withUser.copy(messages = withUser.messages + assistant, modifiedAt = nowFoundationSeconds()).also { saved ->
                                app.library.saveChat(saved)
                                active = saved
                            }
                        }.onFailure { onMessage(it.localizedMessage ?: "The AI request failed.") }
                        busy = false
                    }
                },
            ) { Icon(Icons.AutoMirrored.Filled.Send, contentDescription = "Send question", tint = MaterialTheme.colorScheme.primary) }
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
                    active = null
                    draft = ""
                    if (doomed != null) scope.launch { app.library.removeChat(doomed) }
                }) { Text("Delete") }
            },
            dismissButton = { TextButton(onClick = { confirmDelete = false }) { Text("Cancel") } },
        )
    }
}

private suspend fun boundedBookText(context: android.content.Context, app: CloudReaderApp, book: io.github.haige120.cloudreader.data.BookRow): String? = withContext(Dispatchers.IO) {
    runCatching {
        if (book.format == "txt") {
            app.library.fileFor(book)?.readBytes()?.let(::decodeText)?.take(18_000)
        } else if (book.format == "pdf") {
            PdfReaderActivity.pdfContextFile(context, book.id).takeIf(File::isFile)?.readText()?.take(18_000)
        } else null
    }.getOrNull()
}

@Composable
fun SettingsScreen(
    activity: Activity,
    app: CloudReaderApp,
    onPickFolder: () -> Unit,
    onConnectGoogle: () -> Unit,
    onMessage: (String) -> Unit,
) {
    val scope = rememberCoroutineScope()
    val context = LocalContext.current
    val selected by app.preferences.selectedProviders.collectAsState(initial = emptySet())
    val providerIDs = listOf("googleDrive", "dropbox", "pCloud", "webDAV", "sftp", "filesFolder")
    val providerNames = mapOf("googleDrive" to "Google Drive", "dropbox" to "Dropbox", "pCloud" to "pCloud", "webDAV" to "HTTPS WebDAV", "sftp" to "SFTP", "filesFolder" to "Android folder")

    var dropboxKey by rememberSaveable { mutableStateOf("") }
    var pcloudKey by rememberSaveable { mutableStateOf("") }
    var webdavUrl by rememberSaveable { mutableStateOf("") }
    var webdavUser by rememberSaveable { mutableStateOf("") }
    var webdavPassword by rememberSaveable { mutableStateOf("") }
    var sftpHost by rememberSaveable { mutableStateOf("") }
    var sftpPort by rememberSaveable { mutableStateOf("22") }
    var sftpUser by rememberSaveable { mutableStateOf("") }
    var sftpPassword by rememberSaveable { mutableStateOf("") }
    var sftpDirectory by rememberSaveable { mutableStateOf("CloudReader") }
    var sftpKey by rememberSaveable { mutableStateOf("") }
    var aiName by rememberSaveable { mutableStateOf("My AI") }
    var aiProtocol by rememberSaveable { mutableStateOf("openAIResponses") }
    var aiModel by rememberSaveable { mutableStateOf("") }
    var aiEndpoint by rememberSaveable { mutableStateOf("") }
    var aiKey by rememberSaveable { mutableStateOf("") }
    val folderName by app.preferences.observe("folder.treeUri", "").collectAsState(initial = "")

    LaunchedEffect(Unit) {
        dropboxKey = app.preferences.get("dropbox.appKey").orEmpty()
        pcloudKey = app.preferences.get("pcloud.appKey").orEmpty()
        webdavUrl = app.preferences.get("webdav.url").orEmpty()
        webdavUser = app.vault.get("webdav.username").orEmpty()
        sftpHost = app.vault.get("sftp.host").orEmpty()
        sftpPort = app.vault.get("sftp.port") ?: "22"
        sftpUser = app.vault.get("sftp.username").orEmpty()
        sftpDirectory = app.vault.get("sftp.directory") ?: "CloudReader"
        sftpKey = app.vault.get("sftp.hostKey").orEmpty()
        aiName = app.preferences.get("ai.name") ?: "My AI"
        aiProtocol = app.preferences.get("ai.protocol") ?: "openAIResponses"
        aiModel = app.preferences.get("ai.model").orEmpty()
        aiEndpoint = app.preferences.get("ai.endpoint").orEmpty()
    }

    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal = 22.dp, vertical = 18.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Text("Settings", fontFamily = FontFamily.Serif, fontSize = 29.sp, fontWeight = FontWeight.SemiBold)
        Text("Your connection details stay on this device. Sync copies books, progress, favorites, deletions, and saved conversations.", style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.secondary)
        SectionTitle("Sync destinations")
        providerIDs.forEach { id ->
            val folderReady = id != "filesFolder" || folderName.isNotBlank()
            Row(Modifier.fillMaxWidth().background(Color(0xFFFFFDF7), RoundedCornerShape(14.dp)).clickable { if (folderReady) scope.launch { app.preferences.selectProvider(id, id !in selected) } }.padding(horizontal = 12.dp, vertical = 6.dp), verticalAlignment = Alignment.CenterVertically) {
                Checkbox(checked = id in selected, onCheckedChange = { checked -> if (folderReady) scope.launch { app.preferences.selectProvider(id, checked) } }, enabled = folderReady)
                Column(Modifier.weight(1f)) {
                    Text(providerNames.getValue(id), fontWeight = FontWeight.SemiBold)
                    Text(if (id == "filesFolder" && !folderReady) "Choose a folder below" else if (id in selected) "Selected for foreground sync" else "Not selected", style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.secondary)
                }
                when (id) {
                    "googleDrive" -> TextButton(onClick = onConnectGoogle) { Text(if (id in selected) "Reconnect" else "Connect") }
                    "dropbox" -> TextButton(onClick = {
                        scope.launch { runCatching { OAuthConnector(activity, app.preferences, app.vault).connectDropbox() }.onSuccess { onMessage(it) }.onFailure { onMessage(it.localizedMessage ?: "Dropbox sign-in failed") } }
                    }) { Text("Sign in") }
                    "pCloud" -> TextButton(onClick = {
                        scope.launch { runCatching { OAuthConnector(activity, app.preferences, app.vault).connectPCloud() }.onSuccess { app.preferences.selectProvider(id, true); onMessage(it) }.onFailure { onMessage(it.localizedMessage ?: "pCloud sign-in failed") } }
                    }) { Text("Sign in") }
                    "filesFolder" -> TextButton(onClick = onPickFolder) { Text(if (folderReady) "Change" else "Choose") }
                    else -> Unit
                }
            }
        }
        Field("Dropbox app key", dropboxKey, { dropboxKey = it })
        Field("pCloud app key", pcloudKey, { pcloudKey = it })
        Button(onClick = { scope.launch { app.preferences.set("dropbox.appKey", dropboxKey); app.preferences.set("pcloud.appKey", pcloudKey); onMessage("Provider app identifiers saved") } }) { Text("Save provider app IDs") }

        SectionTitle("HTTPS WebDAV")
        Field("Server URL", webdavUrl, { webdavUrl = it }, placeholder = "https://example.com/dav")
        Field("Username", webdavUser, { webdavUser = it })
        SecretField("Password", webdavPassword, { webdavPassword = it })
        Button(onClick = {
            scope.launch {
                runCatching {
                    require(webdavUrl.startsWith("https://")) { "WebDAV needs an HTTPS URL." }
                    app.preferences.set("webdav.url", webdavUrl.trimEnd('/'))
                    app.vault.put("webdav.username", webdavUser); app.vault.put("webdav.password", webdavPassword)
                    app.preferences.selectProvider("webDAV", true)
                }.onSuccess { onMessage("WebDAV connection saved and selected") }.onFailure { onMessage(it.localizedMessage ?: "WebDAV settings could not be saved") }
            }
        }) { Text("Save WebDAV") }

        SectionTitle("Pinned-host-key SFTP")
        Field("Host", sftpHost, { sftpHost = it })
        Field("Port", sftpPort, { sftpPort = it }, placeholder = "22")
        Field("Username", sftpUser, { sftpUser = it })
        SecretField("Password", sftpPassword, { sftpPassword = it })
        Field("Remote directory", sftpDirectory, { sftpDirectory = it }, placeholder = "CloudReader")
        Field("OpenSSH host public key", sftpKey, { sftpKey = it }, placeholder = "ssh-ed25519 AAAA…")
        Button(onClick = {
            scope.launch {
                runCatching {
                    require(sftpKey.trim().split(Regex("\\s+")).size >= 2) { "Enter the server host public key to pin." }
                    app.vault.put("sftp.host", sftpHost); app.vault.put("sftp.port", sftpPort)
                    app.vault.put("sftp.username", sftpUser); app.vault.put("sftp.password", sftpPassword)
                    app.vault.put("sftp.directory", sftpDirectory.trim('/')); app.vault.put("sftp.hostKey", sftpKey.trim())
                    app.preferences.selectProvider("sftp", true)
                }.onSuccess { onMessage("SFTP details saved and selected") }.onFailure { onMessage(it.localizedMessage ?: "SFTP settings could not be saved") }
            }
        }) { Text("Save pinned SFTP") }

        SectionTitle("Remote AI profile")
        Field("Profile name", aiName, { aiName = it })
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            listOf("openAIResponses", "openAIChatCompletions", "anthropicMessages").forEach { choice ->
                TextButton(onClick = { aiProtocol = choice }, modifier = Modifier.background(if (aiProtocol == choice) Color(0xFFE4EADF) else Color.Transparent, RoundedCornerShape(16.dp))) {
                    Text(when (choice) { "openAIResponses" -> "Responses"; "openAIChatCompletions" -> "Chat Completions"; else -> "Anthropic" }, fontSize = 12.sp)
                }
            }
        }
        Field("Model", aiModel, { aiModel = it }, placeholder = "Model ID")
        Field("Custom HTTPS endpoint (optional)", aiEndpoint, { aiEndpoint = it }, placeholder = "Leave blank for the provider default")
        SecretField("API key", aiKey, { aiKey = it })
        Button(onClick = {
            scope.launch {
                runCatching {
                    require(aiModel.isNotBlank()) { "Add a model ID." }
                    if (aiEndpoint.isNotBlank()) require(aiEndpoint.startsWith("https://")) { "AI endpoints must use HTTPS." }
                    app.preferences.set("ai.name", aiName.ifBlank { "My AI" })
                    app.preferences.set("ai.protocol", aiProtocol); app.preferences.set("ai.model", aiModel.trim()); app.preferences.set("ai.endpoint", aiEndpoint.trim())
                    if (aiKey.isNotBlank()) app.vault.put("ai.apiKey", aiKey.trim())
                }.onSuccess { aiKey = ""; onMessage("AI profile saved") }.onFailure { onMessage(it.localizedMessage ?: "AI settings could not be saved") }
            }
        }) { Text("Save AI profile") }
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
private fun SecretField(label: String, value: String, onValue: (String) -> Unit) {
    OutlinedTextField(value, onValueChange = onValue, modifier = Modifier.fillMaxWidth(), label = { Text(label) }, singleLine = true, visualTransformation = androidx.compose.ui.text.input.PasswordVisualTransformation())
}
