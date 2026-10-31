package io.github.haige120.cloudreader.ui

import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import io.github.haige120.cloudreader.core.application.*

@Composable
fun ReaderToolbar(title: String, progress: String, onClose: () -> Unit, onPrevious: () -> Unit, onNext: () -> Unit,
    onAppearance: () -> Unit, onAsk: () -> Unit, onHide: () -> Unit) {
    Surface(color = MaterialTheme.colorScheme.surface, contentColor = MaterialTheme.colorScheme.onSurface) {
        BoxWithConstraints(Modifier.fillMaxWidth().padding(8.dp)) {
            if(maxWidth>=700.dp) Row(verticalAlignment=Alignment.CenterVertically){
                TextButton(onClick=onClose){Text("Back")}
                Column(Modifier.weight(1f)){Text(title,maxLines=1,overflow=TextOverflow.Ellipsis);Text(progress,style=MaterialTheme.typography.labelSmall)}
                TextButton(onClick=onPrevious,modifier=Modifier.semantics{contentDescription="Previous page"}){Text("‹")}
                TextButton(onClick=onNext,modifier=Modifier.semantics{contentDescription="Next page"}){Text("›")}
                TextButton(onClick=onAppearance){Text("Aa")};TextButton(onClick=onAsk){Text("Ask AI")}
                TextButton(onClick=onHide){Text("Hide")}
            }else Column{
                Row(verticalAlignment=Alignment.CenterVertically){
                    TextButton(onClick=onClose){Text("Back")}
                    Column(Modifier.weight(1f)){Text(title,maxLines=1,overflow=TextOverflow.Ellipsis);Text(progress,maxLines=1,style=MaterialTheme.typography.labelSmall)}
                    TextButton(onClick=onHide){Text("Hide")}
                }
                Row(Modifier.fillMaxWidth(),horizontalArrangement=Arrangement.SpaceEvenly){
                    TextButton(onClick=onPrevious){Text("Previous")};TextButton(onClick=onNext){Text("Next")}
                    TextButton(onClick=onAppearance){Text("Aa")};TextButton(onClick=onAsk){Text("Ask AI")}
                }
            }
        }
    }
}

@Composable
fun AppearanceDialog(value: ReadingAppearance, onChange: (ReadingAppearance) -> Unit, onDismiss: () -> Unit) {
    AlertDialog(onDismissRequest = onDismiss, title = { Text("Reading appearance") }, text = {
        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text("Text size: ${value.fontSize}")
            Slider(value.fontSize.toFloat(), { onChange(value.copy(fontSize = it.toInt()).validated()) }, valueRange = 14f..38f)
            Row { listOf("Serif", "Sans", "Mono").forEach { family -> TextButton(onClick = { onChange(value.copy(family = family)) }) { Text(if (family == value.family) "✓ $family" else family) } } }
            Row { listOf("System", "Light", "Sepia", "Dark").forEach { theme -> TextButton(onClick = { onChange(value.copy(theme = theme)) }, contentPadding = PaddingValues(4.dp)) { Text(if (value.theme == theme) "✓ $theme" else theme) } } }
            TextButton(onClick = { onChange(value.copy(theme = "Custom")) }) { Text(if (value.theme == "Custom") "✓ Custom colors" else "Custom colors") }
            if (value.theme == "Custom") {
                OutlinedTextField(value.customBackground, { onChange(value.copy(customBackground = it)) }, label = { Text("Page color (#RRGGBB)") })
                OutlinedTextField(value.customForeground, { onChange(value.copy(customForeground = it)) }, label = { Text("Text color (#RRGGBB)") })
            }
            Column { ReaderLayout.entries.forEach { layout ->
                TextButton(onClick = { onChange(value.copy(layout = layout)) }) { Text((if (value.layout == layout) "✓ " else "") + when (layout) { ReaderLayout.SCROLL -> "Scrolling"; ReaderLayout.PAGE -> "One page"; ReaderLayout.SPREAD -> "Two pages on wide windows" }) }
            } }
        }
    }, confirmButton = { TextButton(onClick = onDismiss) { Text("Done") } })
}
