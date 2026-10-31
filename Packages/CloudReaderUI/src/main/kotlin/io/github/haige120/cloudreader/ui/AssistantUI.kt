package io.github.haige120.cloudreader.ui

import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import io.github.haige120.cloudreader.core.model.ChatRecord

@Composable
fun AssistantContent(chats: List<ChatRecord>, active: ChatRecord?, draft: String, busy: Boolean,
    includeContext: Boolean, contextPreview: String?, error: String?, profileLabel: String,
    onDraft: (String) -> Unit, onSelect: (String) -> Unit, onNew: () -> Unit,
    onConsent: (Boolean) -> Unit, onSend: () -> Unit, onCancel: () -> Unit, onRetry: () -> Unit,
    onDelete: () -> Unit, onShare: (() -> Unit)? = null) {
    var deleting by remember { mutableStateOf(false) }
    Column(Modifier.fillMaxSize().padding(20.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Column(Modifier.weight(1f)) {
                Text("Ask CloudReader", fontFamily = FontFamily.Serif, fontSize = 28.sp)
                Text(profileLabel, style = MaterialTheme.typography.labelMedium)
            }
            onShare?.let { TextButton(onClick = it) { Text("Share") } }
            TextButton(onClick = onNew) { Text("New") }
            if (active != null) TextButton(onClick = { deleting = true }) { Text("Delete") }
        }
        if (chats.isNotEmpty()) Row(Modifier.fillMaxWidth().horizontalScroll(rememberScrollState())) {
            chats.forEach { chat -> TextButton(onClick = { onSelect(chat.id) }) { Text(chat.title.take(30)) } }
        }
        LazyColumn(Modifier.weight(1f).fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            if (active?.messages.isNullOrEmpty()) item {
                Column(Modifier.padding(vertical = 36.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    Text("What are you reading today?", fontFamily = FontFamily.Serif, fontSize = 24.sp)
                    Text("Questions go to the AI service you configure. Saved conversations sync with your library.")
                }
            }
            items(active?.messages.orEmpty(), key = { it.id }) { message ->
                Card(colors = CardDefaults.cardColors(containerColor = if (message.role == "user") MaterialTheme.colorScheme.secondaryContainer else MaterialTheme.colorScheme.surface)) {
                    SelectionContainer { Text(message.text, modifier = Modifier.fillMaxWidth().padding(14.dp)) }
                }
            }
            if (busy) item { CircularProgressIndicator() }
        }
        if (contextPreview != null) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Checkbox(includeContext, onCheckedChange = onConsent)
                Column(Modifier.weight(1f)) {
                    Text("Include selected passage or book text")
                    Text("Sent only with consent · up to 18,000 characters · saved with this chat and synced", style = MaterialTheme.typography.labelSmall)
                }
            }
            Text(contextPreview.take(240), style = MaterialTheme.typography.bodySmall, maxLines = 3)
        }
        error?.let { Text(it, color = MaterialTheme.colorScheme.error, maxLines = 3) }
        Row(verticalAlignment = Alignment.Bottom, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            OutlinedTextField(draft, onDraft, label = { Text("Ask a question") }, modifier = Modifier.weight(1f), maxLines = 5, enabled = !busy)
            if (busy) TextButton(onClick = onCancel) { Text("Stop") }
            else {
                if (error != null) TextButton(onClick = onRetry) { Text("Retry") }
                Button(onClick = onSend, enabled = draft.isNotBlank()) { Text("Send") }
            }
        }
    }
    if (deleting) AlertDialog(onDismissRequest = { deleting = false }, title = { Text("Delete conversation?") },
        text = { Text("Its deletion will sync to your selected destinations.") },
        confirmButton = { TextButton(onClick = { deleting = false; onDelete() }) { Text("Delete") } },
        dismissButton = { TextButton(onClick = { deleting = false }) { Text("Cancel") } })
}
