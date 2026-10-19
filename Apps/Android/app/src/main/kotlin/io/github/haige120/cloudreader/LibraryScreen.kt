package io.github.haige120.cloudreader

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Bookmark
import androidx.compose.material.icons.filled.DeleteOutline
import androidx.compose.material.icons.filled.Favorite
import androidx.compose.material.icons.filled.FavoriteBorder
import androidx.compose.material.icons.automirrored.filled.MenuBook
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.UploadFile
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import io.github.haige120.cloudreader.data.BookRow

@Composable
fun LibraryScreen(
    app: CloudReaderApp,
    onImport: () -> Unit,
    onOpen: (BookRow) -> Unit,
    onAsk: (BookRow, String?) -> Unit,
    onRemove: (BookRow) -> Unit,
    onToggleFavorite: (BookRow) -> Unit,
) {
    val books by app.library.books.collectAsState(initial = emptyList())
    var search by rememberSaveable { mutableStateOf("") }
    var favoritesOnly by rememberSaveable { mutableStateOf(false) }
    val sync by app.syncOutcome.collectAsState()
    val syncStatus = when {
        sync?.failed?.isNotEmpty() == true -> "Sync needs attention"
        !sync?.successful.isNullOrEmpty() -> "Synced to ${sync!!.successful.size} destinations"
        else -> "Your shelf is ready offline"
    }
    val ordered = books.sortedWith(compareByDescending<BookRow> { it.lastOpenedAt != null }.thenByDescending { it.lastOpenedAt ?: it.addedAt })
    val latest = ordered.firstOrNull { it.lastOpenedAt != null }
    val shown = ordered.filter { (!favoritesOnly || it.isBookmarked) && (search.isBlank() || it.title.contains(search, true) || it.author?.contains(search, true) == true) }

    Column(Modifier.fillMaxSize().padding(horizontal = 22.dp)) {
        Row(Modifier.fillMaxWidth().padding(top = 22.dp, bottom = 18.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.SpaceBetween) {
            Column {
                Text("CloudReader", fontFamily = FontFamily.Serif, fontSize = 30.sp, fontWeight = FontWeight.SemiBold, color = MaterialTheme.colorScheme.onBackground)
                Text(syncStatus, style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.secondary)
            }
            IconButton(onClick = onImport) { Icon(Icons.Filled.Add, contentDescription = "Import books", tint = MaterialTheme.colorScheme.primary) }
        }
        if (latest != null) {
            Text("CONTINUE READING", style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.secondary, fontWeight = FontWeight.Bold, letterSpacing = 1.1.sp)
            ContinueCard(latest, onClick = { onOpen(latest) })
            Spacer(Modifier.height(22.dp))
        }
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.SpaceBetween, modifier = Modifier.fillMaxWidth()) {
            Text("Your shelf", fontFamily = FontFamily.Serif, fontSize = 25.sp, fontWeight = FontWeight.SemiBold)
            TextButton(onClick = { favoritesOnly = !favoritesOnly }) {
                Icon(if (favoritesOnly) Icons.Filled.Favorite else Icons.Filled.FavoriteBorder, null, modifier = Modifier.size(17.dp))
                Spacer(Modifier.width(5.dp)); Text(if (favoritesOnly) "Favorites" else "All books")
            }
        }
        OutlinedTextField(
            value = search, onValueChange = { search = it }, modifier = Modifier.fillMaxWidth(), singleLine = true,
            leadingIcon = { Icon(Icons.Filled.Search, contentDescription = null) }, placeholder = { Text("Search your books") },
            shape = RoundedCornerShape(16.dp),
        )
        Spacer(Modifier.height(10.dp))
        if (books.isEmpty()) {
            Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                Column(horizontalAlignment = Alignment.CenterHorizontally) {
                    Icon(Icons.AutoMirrored.Filled.MenuBook, null, tint = MaterialTheme.colorScheme.secondary, modifier = Modifier.size(45.dp))
                    Spacer(Modifier.height(12.dp)); Text("Make room for a good book", fontFamily = FontFamily.Serif, fontSize = 22.sp)
                    Text("Imported books stay available offline.", color = MaterialTheme.colorScheme.secondary)
                    Spacer(Modifier.height(12.dp)); Button(onClick = onImport) { Icon(Icons.Filled.UploadFile, null); Spacer(Modifier.width(8.dp)); Text("Import books") }
                }
            }
        } else if (shown.isEmpty()) {
            Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) { Text("No books match that search.", color = MaterialTheme.colorScheme.secondary) }
        } else {
            LazyVerticalGrid(
                columns = GridCells.Adaptive(minSize = 164.dp),
                modifier = Modifier.weight(1f).fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(14.dp), verticalArrangement = Arrangement.spacedBy(14.dp),
                contentPadding = androidx.compose.foundation.layout.PaddingValues(top = 8.dp, bottom = 26.dp),
            ) {
                items(shown, key = { it.id }) { book ->
                    BookTile(book, onOpen = { onOpen(book) }, onAsk = { onAsk(book, null) }, onRemove = { onRemove(book) }, onFavorite = { onToggleFavorite(book) })
                }
            }
        }
    }
}

@Composable
private fun ContinueCard(book: BookRow, onClick: () -> Unit) {
    Card(onClick = onClick, modifier = Modifier.fillMaxWidth().padding(top = 9.dp), shape = RoundedCornerShape(20.dp), colors = CardDefaults.cardColors(containerColor = Color(0xFFE8EDE5))) {
        Row(Modifier.padding(16.dp), verticalAlignment = Alignment.CenterVertically) {
            BookCover(book, Modifier.size(width = 72.dp, height = 93.dp))
            Column(Modifier.weight(1f).padding(start = 16.dp)) {
                Text(book.title, fontFamily = FontFamily.Serif, fontSize = 21.sp, fontWeight = FontWeight.SemiBold, maxLines = 2, overflow = TextOverflow.Ellipsis)
                Text(book.author ?: book.format.uppercase(), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.secondary)
                Spacer(Modifier.height(13.dp))
                LinearProgressIndicator(progress = { book.progress.toFloat() }, modifier = Modifier.fillMaxWidth().height(5.dp).clip(RoundedCornerShape(6.dp)), color = MaterialTheme.colorScheme.primary, trackColor = Color.White)
                Text("${(book.progress * 100).toInt()}% read", style = MaterialTheme.typography.labelSmall, modifier = Modifier.padding(top = 5.dp), color = MaterialTheme.colorScheme.secondary)
            }
            Spacer(Modifier.width(12.dp))
            Icon(Icons.Filled.Bookmark, contentDescription = null, tint = MaterialTheme.colorScheme.primary)
        }
    }
}

@Composable
private fun BookTile(book: BookRow, onOpen: () -> Unit, onAsk: () -> Unit, onRemove: () -> Unit, onFavorite: () -> Unit) {
    Card(shape = RoundedCornerShape(18.dp), colors = CardDefaults.cardColors(containerColor = Color(0xFFFFFDF7))) {
        Column(Modifier.fillMaxWidth().clickable(onClick = onOpen).padding(12.dp)) {
            Box(Modifier.fillMaxWidth().aspectRatio(0.82f)) {
                BookCover(book, Modifier.fillMaxSize())
                IconButton(onClick = onFavorite, modifier = Modifier.align(Alignment.TopEnd).padding(3.dp).size(38.dp)) {
                    Icon(if (book.isBookmarked) Icons.Filled.Favorite else Icons.Filled.FavoriteBorder, contentDescription = if (book.isBookmarked) "Remove favorite" else "Add favorite", tint = if (book.isBookmarked) Color(0xFF9F5350) else Color(0xFF655D52))
                }
            }
            Spacer(Modifier.height(10.dp))
            Text(book.title, maxLines = 2, overflow = TextOverflow.Ellipsis, fontFamily = FontFamily.Serif, fontWeight = FontWeight.SemiBold, fontSize = 16.sp, minLines = 2)
            Text(book.author ?: book.format.uppercase(), maxLines = 1, overflow = TextOverflow.Ellipsis, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.secondary)
            Spacer(Modifier.height(8.dp))
            if (book.progress > 0) LinearProgressIndicator(progress = { book.progress.toFloat() }, modifier = Modifier.fillMaxWidth().height(3.dp), color = MaterialTheme.colorScheme.primary)
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                Text("${(book.progress * 100).toInt()}%", style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.secondary, modifier = Modifier.weight(1f))
                TextButton(onClick = onAsk, contentPadding = androidx.compose.foundation.layout.PaddingValues(horizontal = 5.dp)) { Text("Ask AI", style = MaterialTheme.typography.labelSmall) }
                IconButton(onClick = onRemove, modifier = Modifier.size(36.dp)) { Icon(Icons.Filled.DeleteOutline, contentDescription = "Remove ${book.title}", tint = Color(0xFF80654B)) }
            }
        }
    }
}

@Composable
private fun BookCover(book: BookRow, modifier: Modifier = Modifier) {
    val colors = listOf(Color(0xFF536D59), Color(0xFF80654B), Color(0xFF697D82), Color(0xFF9A7760), Color(0xFF7A6654))
    val swatch = colors[(book.title.sumOf(Char::code) % colors.size)]
    Column(modifier.clip(RoundedCornerShape(12.dp)).background(swatch).padding(11.dp), verticalArrangement = Arrangement.SpaceBetween) {
        Text("CLOUDREADER", fontSize = 8.sp, letterSpacing = 1.3.sp, fontWeight = FontWeight.Bold, color = Color.White.copy(alpha = .78f))
        Text(book.title, fontFamily = FontFamily.Serif, color = Color.White, fontSize = 16.sp, lineHeight = 18.sp, fontWeight = FontWeight.SemiBold, maxLines = 4, overflow = TextOverflow.Ellipsis)
        Text(book.format.uppercase(), fontSize = 9.sp, color = Color.White.copy(alpha = .84f), letterSpacing = 1.sp)
    }
}
