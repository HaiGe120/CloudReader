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
fun LibraryScreen(app: CloudReaderApp, actions: LibraryScreenActions) {
    val model: LibraryViewModel = viewModel(factory = LibraryViewModel.factory(app))
    val state by model.state.collectAsStateWithLifecycle()
    val status = when {
        state.syncOutcome?.failed?.isNotEmpty() == true -> "Sync needs attention"
        !state.syncOutcome?.successful.isNullOrEmpty() -> "Synced to ${state.syncOutcome!!.successful.size} destinations"
        else -> "Your shelf is ready offline"
    }
    io.github.haige120.cloudreader.ui.LibraryContent(
        books = state.books, search = state.searchQuery, favoritesOnly = state.favoritesOnly,
        syncStatus = status, onSearch = model::search, onFavorites = model::toggleFavorites,
        onImport = actions.onImport, onSync = actions.onSync, onOpen = actions.onOpen,
        onAsk = { actions.onAsk(it, null) }, onFavorite = actions.onToggleFavorite, onRemove = actions.onRemove,
    )
}
