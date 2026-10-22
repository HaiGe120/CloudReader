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
import androidx.compose.foundation.shape.RoundedCornerShape
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
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.SavedStateHandle
import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.createSavedStateHandle
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewModelScope
import androidx.lifecycle.viewmodel.CreationExtras
import androidx.lifecycle.viewmodel.compose.viewModel
import io.github.haige120.cloudreader.domain.BookRecord
import io.github.haige120.cloudreader.sync.SyncOutcome
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.stateIn

data class LibraryScreenState(
    val books: List<BookRecord> = emptyList(),
    val searchQuery: String = "",
    val favoritesOnly: Boolean = false,
    val syncOutcome: SyncOutcome? = null,
) {
    val orderedBooks: List<BookRecord> get() = books.sortedWith(
        compareByDescending<BookRecord> { it.lastOpenedAt != null }
            .thenByDescending { it.lastOpenedAt ?: it.addedAt },
    )
    val latestBook: BookRecord? get() = orderedBooks.firstOrNull { it.lastOpenedAt != null }
    val visibleBooks: List<BookRecord> get() = orderedBooks.filter {
        (!favoritesOnly || it.isBookmarked) &&
            (searchQuery.isBlank() || it.title.contains(searchQuery, true) || it.author?.contains(searchQuery, true) == true)
    }
}

data class LibraryScreenActions(
    val onSync: () -> Unit,
    val onImport: () -> Unit,
    val onOpen: (BookRecord) -> Unit,
    val onAsk: (BookRecord, String?) -> Unit,
    val onRemove: (BookRecord) -> Unit,
    val onToggleFavorite: (BookRecord) -> Unit,
)

class LibraryViewModel(
    private val savedState: SavedStateHandle,
    books: kotlinx.coroutines.flow.Flow<List<BookRecord>>,
    syncOutcomes: kotlinx.coroutines.flow.Flow<SyncOutcome?>,
    stateScope: CoroutineScope? = null,
) : ViewModel() {
    private val searchQuery = MutableStateFlow(savedState[SEARCH_KEY] ?: "")
    private val favoritesOnly = MutableStateFlow(savedState[FAVORITES_KEY] ?: false)

    val state: StateFlow<LibraryScreenState> = combine(books, searchQuery, favoritesOnly, syncOutcomes) { currentBooks, query, favorites, outcome ->
        LibraryScreenState(currentBooks.toList(), query, favorites, outcome)
    }.stateIn(stateScope ?: viewModelScope, SharingStarted.WhileSubscribed(5_000), LibraryScreenState(
        searchQuery = searchQuery.value,
        favoritesOnly = favoritesOnly.value,
    ))

    fun search(query: String) {
        savedState[SEARCH_KEY] = query
        searchQuery.value = query
    }

    fun toggleFavorites() {
        val next = !favoritesOnly.value
        savedState[FAVORITES_KEY] = next
        favoritesOnly.value = next
    }

    companion object {
        private const val SEARCH_KEY = "library.search"
        private const val FAVORITES_KEY = "library.favoritesOnly"

        fun factory(app: CloudReaderApp): ViewModelProvider.Factory = object : ViewModelProvider.Factory {
            @Suppress("UNCHECKED_CAST")
            override fun <T : ViewModel> create(modelClass: Class<T>, extras: CreationExtras): T {
                require(LibraryViewModel::class.java.isAssignableFrom(modelClass))
                return LibraryViewModel(extras.createSavedStateHandle(), app.library.books, app.syncOutcome) as T
            }
        }
    }
}

@Composable
fun LibraryScreen(
    app: CloudReaderApp,
    actions: LibraryScreenActions,
) {
    val model: LibraryViewModel = viewModel(factory = LibraryViewModel.factory(app))
    val state by model.state.collectAsStateWithLifecycle()
    val books = state.books
    val search = state.searchQuery
    val favoritesOnly = state.favoritesOnly
    val sync = state.syncOutcome
    val syncStatus = when {
        sync?.failed?.isNotEmpty() == true -> "Sync needs attention"
        !sync?.successful.isNullOrEmpty() -> "Synced to ${sync.successful.size} destinations"
        else -> "Your shelf is ready offline"
    }
    val latest = state.latestBook
    val shown = state.visibleBooks

    Column(Modifier.fillMaxSize().padding(horizontal = 22.dp)) {
        Row(Modifier.fillMaxWidth().padding(top = 22.dp, bottom = 18.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.SpaceBetween) {
            Column {
                Text("CloudReader", fontFamily = FontFamily.Serif, fontSize = 30.sp, fontWeight = FontWeight.SemiBold, color = MaterialTheme.colorScheme.onBackground)
                Text(syncStatus, style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.secondary)
            }
            Row(verticalAlignment = Alignment.CenterVertically) {
                TextButton(onClick = actions.onSync) { Text("Sync now") }
                IconButton(onClick = actions.onImport) { Icon(Icons.Filled.Add, contentDescription = "Import books", tint = MaterialTheme.colorScheme.primary) }
            }
        }
        if (latest != null) {
            Text("CONTINUE READING", style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.secondary, fontWeight = FontWeight.Bold, letterSpacing = 1.1.sp)
            ContinueCard(latest, onClick = { actions.onOpen(latest) })
            Spacer(Modifier.height(22.dp))
        }
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.SpaceBetween, modifier = Modifier.fillMaxWidth()) {
            Text("Your shelf", fontFamily = FontFamily.Serif, fontSize = 25.sp, fontWeight = FontWeight.SemiBold)
            TextButton(onClick = model::toggleFavorites) {
                Icon(if (favoritesOnly) Icons.Filled.Favorite else Icons.Filled.FavoriteBorder, null, modifier = Modifier.size(17.dp))
                Spacer(Modifier.width(5.dp)); Text(if (favoritesOnly) "Favorites" else "All books")
            }
        }
        OutlinedTextField(
            value = search, onValueChange = model::search, modifier = Modifier.fillMaxWidth(), singleLine = true,
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
                    Spacer(Modifier.height(12.dp)); Button(onClick = actions.onImport) { Icon(Icons.Filled.UploadFile, null); Spacer(Modifier.width(8.dp)); Text("Import books") }
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
                    BookTile(book, onOpen = { actions.onOpen(book) }, onAsk = { actions.onAsk(book, null) }, onRemove = { actions.onRemove(book) }, onFavorite = { actions.onToggleFavorite(book) })
                }
            }
        }
    }
}

@Composable
private fun ContinueCard(book: BookRecord, onClick: () -> Unit) {
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
private fun BookTile(book: BookRecord, onOpen: () -> Unit, onAsk: () -> Unit, onRemove: () -> Unit, onFavorite: () -> Unit) {
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
private fun BookCover(book: BookRecord, modifier: Modifier = Modifier) {
    val colors = listOf(Color(0xFF536D59), Color(0xFF80654B), Color(0xFF697D82), Color(0xFF9A7760), Color(0xFF7A6654))
    val swatch = colors[(book.title.sumOf(Char::code) % colors.size)]
    Column(modifier.clip(RoundedCornerShape(12.dp)).background(swatch).padding(11.dp), verticalArrangement = Arrangement.SpaceBetween) {
        Text("CLOUDREADER", fontSize = 8.sp, letterSpacing = 1.3.sp, fontWeight = FontWeight.Bold, color = Color.White.copy(alpha = .78f))
        Text(book.title, fontFamily = FontFamily.Serif, color = Color.White, fontSize = 16.sp, lineHeight = 18.sp, fontWeight = FontWeight.SemiBold, maxLines = 4, overflow = TextOverflow.Ellipsis)
        Text(book.format.uppercase(), fontSize = 9.sp, color = Color.White.copy(alpha = .84f), letterSpacing = 1.sp)
    }
}
