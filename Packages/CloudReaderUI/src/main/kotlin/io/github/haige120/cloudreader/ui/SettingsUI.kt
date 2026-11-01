package io.github.haige120.cloudreader.ui

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp

/** A surface and its text always use the same palette, including in dark mode. */
@Composable
fun SyncDestinationCard(
    title: String,
    subtitle: String,
    selected: Boolean,
    enabled: Boolean = true,
    onSelected: (Boolean) -> Unit,
    actions: @Composable RowScope.() -> Unit = {},
) {
    val colors = MaterialTheme.colorScheme
    val background = if (selected) colors.secondaryContainer else colors.surface
    val foreground = if (selected) colors.onSecondaryContainer else colors.onSurface
    Surface(
        modifier = Modifier.fillMaxWidth(), shape = RoundedCornerShape(16.dp),
        color = background, contentColor = foreground,
        border = BorderStroke(1.dp, if (selected) colors.primary else colors.outline),
    ) {
        Column(Modifier.padding(8.dp)) {
            Row(
                Modifier.fillMaxWidth().toggleable(selected, enabled = enabled, role = Role.Checkbox, onValueChange = onSelected),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Checkbox(checked = selected, onCheckedChange = null, enabled = enabled, modifier = Modifier.padding(12.dp))
                Column(Modifier.weight(1f).padding(vertical = 8.dp, horizontal = 4.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    Text(title, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
                    Text(subtitle, style = MaterialTheme.typography.bodyMedium)
                }
            }
            // A separate action row leaves room for long labels and larger system fonts.
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End, verticalAlignment = Alignment.CenterVertically, content = actions)
        }
    }
}

/** Readable summary first; verbose provider diagnostics remain available on demand. */
@Composable
fun ConnectionStatus(message: String, needsAttention: Boolean, onSetup: (() -> Unit)? = null) {
    var expanded by remember(message) { mutableStateOf(false) }
    val colors = MaterialTheme.colorScheme
    Surface(
        modifier = Modifier.fillMaxWidth(), shape = RoundedCornerShape(12.dp),
        color = if (needsAttention) colors.errorContainer else colors.surfaceVariant,
        contentColor = if (needsAttention) colors.onErrorContainer else colors.onSurfaceVariant,
    ) {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text(message.substringBefore('\n'), style = MaterialTheme.typography.bodyMedium)
            onSetup?.let { TextButton(onClick = it, colors = ButtonDefaults.textButtonColors(contentColor = colors.onErrorContainer)) { Text("Google connection help") } }
            if (message.contains('\n')) {
                TextButton(onClick = { expanded = !expanded }, colors = ButtonDefaults.textButtonColors(contentColor = LocalContentColor.current)) {
                    Text(if (expanded) "Hide technical details" else "Show technical details")
                }
                if (expanded) SelectionContainer { Text(message.substringAfter('\n'), style = MaterialTheme.typography.bodyMedium) }
            }
        }
    }
}
