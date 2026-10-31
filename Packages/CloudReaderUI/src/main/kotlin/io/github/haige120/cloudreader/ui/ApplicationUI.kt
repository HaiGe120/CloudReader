package io.github.haige120.cloudreader.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import io.github.haige120.cloudreader.core.application.*
import io.github.haige120.cloudreader.core.model.BookRecord

@Composable
fun CloudReaderTheme(content: @Composable () -> Unit) {
    val palette = if (isSystemInDarkTheme()) darkColorScheme(
        primary = Color(0xFFB9CDB9), secondary = Color(0xFFD4BA9E), background = Color(0xFF20211E), surface = Color(0xFF292A26),
        secondaryContainer = Color(0xFF354438), onSecondaryContainer = Color(0xFFE0EBDD), surfaceVariant = Color(0xFF33372F),
    ) else lightColorScheme(
        primary = Color(0xFF536D59), secondary = Color(0xFF80654B), background = Color(0xFFF7F3E9), surface = Color(0xFFFFFDF7),
        onSurface = Color(0xFF292621), onBackground = Color(0xFF292621),
        secondaryContainer = Color(0xFFE1E8DC), onSecondaryContainer = Color(0xFF29382D), surfaceVariant = Color(0xFFEAE8DE),
    )
    MaterialTheme(colorScheme = palette, content = content)
}

@Composable
fun CloudReaderShell(destination: AppDestination, onDestination: (AppDestination) -> Unit,
    snackbar: SnackbarHostState, content: @Composable () -> Unit) {
    BoxWithConstraints(Modifier.fillMaxSize()) {
        val wide = maxWidth >= 840.dp
        Scaffold(containerColor = MaterialTheme.colorScheme.background,
            snackbarHost = { SnackbarHost(snackbar) }, bottomBar = {
                if (!wide) NavigationBar {
                    AppDestination.entries.forEach { item -> NavigationBarItem(
                        selected = destination == item, onClick = { onDestination(item) },
                        icon = { Text(when(item) { AppDestination.LIBRARY -> "▤"; AppDestination.ASSISTANT -> "✦"; AppDestination.SETTINGS -> "⚙" }) },
                        label = { Text(item.label) }) }
                }
            }) { insets ->
            Row(Modifier.fillMaxSize().padding(insets)) {
                if (wide) Column(Modifier.width(170.dp).fillMaxHeight().padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    Text("CLOUDREADER", letterSpacing = 2.sp, style = MaterialTheme.typography.labelSmall)
                    Spacer(Modifier.height(16.dp))
                    AppDestination.entries.forEach { item ->
                        if (destination == item) FilledTonalButton(onClick = { onDestination(item) }, modifier = Modifier.fillMaxWidth()) { Text(item.label) }
                        else TextButton(onClick = { onDestination(item) }, modifier = Modifier.fillMaxWidth()) { Text(item.label) }
                    }
                }
                Box(Modifier.weight(1f).fillMaxHeight()) { content() }
            }
        }
    }
}

@Composable
fun LibraryContent(books: List<BookRecord>, search: String, favoritesOnly: Boolean, syncStatus: String,
    onSearch: (String) -> Unit, onFavorites: () -> Unit, onImport: () -> Unit, onSync: () -> Unit,
    onOpen: (BookRecord) -> Unit, onAsk: (BookRecord) -> Unit, onFavorite: (BookRecord) -> Unit, onRemove: (BookRecord) -> Unit) {
    val state = remember(books, search, favoritesOnly) { LibraryPresentation(books, search, favoritesOnly) }
    var removing by remember { mutableStateOf<BookRecord?>(null) }
    Column(Modifier.fillMaxSize().padding(horizontal = 22.dp)) {
        Row(Modifier.fillMaxWidth().padding(top = 20.dp, bottom = 16.dp), verticalAlignment = Alignment.CenterVertically) {
            Column(Modifier.weight(1f)) {
                Text("Library", fontFamily = FontFamily.Serif, fontWeight = FontWeight.SemiBold, fontSize = 32.sp)
                Text(syncStatus, style = MaterialTheme.typography.labelMedium)
            }
            TextButton(onClick = onSync) { Text("Sync now") }
            FilledTonalButton(onClick = onImport) { Text("+ Import") }
        }
        LazyVerticalGrid(columns = GridCells.Adaptive(155.dp), modifier = Modifier.weight(1f),
            horizontalArrangement = Arrangement.spacedBy(14.dp), verticalArrangement = Arrangement.spacedBy(14.dp), contentPadding = PaddingValues(bottom = 24.dp)) {
            item(span = { androidx.compose.foundation.lazy.grid.GridItemSpan(maxLineSpan) }) {
                Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    state.continuing?.let { book ->
                        Card(onClick = { onOpen(book) }, colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.secondaryContainer)) {
                            Column(Modifier.fillMaxWidth().padding(20.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                                Text("CONTINUE READING", style = MaterialTheme.typography.labelSmall, letterSpacing = 1.sp)
                                Text(book.title, fontFamily = FontFamily.Serif, fontSize = 23.sp, maxLines = 2, overflow = TextOverflow.Ellipsis)
                                LinearProgressIndicator(progress = { book.progress.toFloat() }, modifier = Modifier.fillMaxWidth())
                                Text("${(book.progress * 100).toInt()}% read", style = MaterialTheme.typography.labelSmall)
                            }
                        }
                    }
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text("Your shelf", fontFamily = FontFamily.Serif, fontSize = 24.sp, modifier = Modifier.weight(1f))
                        TextButton(onClick = onFavorites) { Text(if (favoritesOnly) "♥ Favorites" else "All books") }
                    }
                    OutlinedTextField(search, onSearch, singleLine = true, label = { Text("Search your library") }, modifier = Modifier.fillMaxWidth(), shape = RoundedCornerShape(16.dp))
                    Text("${state.visible.size} ${if(state.visible.size==1)"book" else "books"}", style = MaterialTheme.typography.labelMedium)
                    if (state.visible.isEmpty()) {
                        Text(if (books.isEmpty()) "A quiet home for your books. Import a book to begin." else "No books match this view.", modifier = Modifier.padding(vertical = 20.dp))
                    }
                }
            }
            items(state.visible, key = { it.id }) { book ->
                Card(shape = RoundedCornerShape(18.dp)) {
                    Column(Modifier.fillMaxWidth().padding(10.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                        val swatches = listOf(0xFF536D59, 0xFF80654B, 0xFF697D82, 0xFF946E62, 0xFF776783)
                        Box(Modifier.fillMaxWidth().aspectRatio(.78f).clip(RoundedCornerShape(12.dp))
                            .background(Color(swatches[(book.title.hashCode() and Int.MAX_VALUE) % swatches.size]))
                            .clickable { onOpen(book) }.padding(12.dp).semantics { contentDescription = "Open ${book.title}" }) {
                            Text("CLOUDREADER", color = Color.White.copy(alpha = .7f), fontSize = 8.sp, letterSpacing = 1.sp)
                            Text(book.title, modifier = Modifier.align(Alignment.CenterStart), color = Color.White, fontFamily = FontFamily.Serif, fontWeight = FontWeight.SemiBold, maxLines = 5, overflow = TextOverflow.Ellipsis)
                            Text(book.format.uppercase(), modifier = Modifier.align(Alignment.BottomStart), color = Color.White, style = MaterialTheme.typography.labelSmall)
                        }
                        Text(book.title, fontFamily = FontFamily.Serif, maxLines = 2, minLines = 2, overflow = TextOverflow.Ellipsis)
                        Text(book.author ?: book.format.uppercase(), style = MaterialTheme.typography.labelSmall, maxLines = 1, overflow = TextOverflow.Ellipsis)
                        LinearProgressIndicator(progress = { book.progress.toFloat() }, modifier = Modifier.fillMaxWidth().height(3.dp))
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            TextButton(onClick = { onFavorite(book) }, contentPadding = PaddingValues(0.dp), modifier = Modifier.width(40.dp).semantics { contentDescription = if (book.isBookmarked) "Remove favorite" else "Add favorite" }) { Text(if (book.isBookmarked) "♥" else "♡") }
                            TextButton(onClick = { onAsk(book) }, contentPadding = PaddingValues(4.dp), modifier = Modifier.weight(1f)) { Text("Ask AI", maxLines = 1) }
                            TextButton(onClick = { removing = book }, contentPadding = PaddingValues(0.dp), modifier = Modifier.width(32.dp).semantics { contentDescription = "Remove ${book.title}" }) { Text("×") }
                        }
                    }
                }
            }
        }
    }
    removing?.let { book -> AlertDialog(onDismissRequest = { removing = null }, title = { Text("Remove from library?") },
        text = { Text("Remove ${book.title} and sync its deletion to your selected destinations? Your original imported file is kept.") },
        confirmButton = { TextButton(onClick = { onRemove(book); removing = null }) { Text("Remove") } },
        dismissButton = { TextButton(onClick = { removing = null }) { Text("Cancel") } }) }
}
