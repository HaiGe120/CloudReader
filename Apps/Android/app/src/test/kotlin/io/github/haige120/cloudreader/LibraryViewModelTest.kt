package io.github.haige120.cloudreader

import androidx.lifecycle.SavedStateHandle
import io.github.haige120.cloudreader.domain.BookRecord
import io.github.haige120.cloudreader.sync.SyncOutcome
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class LibraryViewModelTest {
    @Test fun filtersFavoritesAndSearchAndReflectsReloadedLibrary() = runTest {
        val books = MutableStateFlow(listOf(book("1", "Dune", favorite = true), book("2", "Solaris")))
        val outcomes = MutableStateFlow<SyncOutcome?>(null)
        val model = LibraryViewModel(SavedStateHandle(), books, outcomes, backgroundScope)
        val collect = backgroundScope.launch { model.state.collect {} }
        runCurrent()

        model.toggleFavorites()
        runCurrent()
        assertEquals(listOf("1"), model.state.value.visibleBooks.map(BookRecord::id))
        model.search("solar")
        runCurrent()
        assertEquals(emptyList<String>(), model.state.value.visibleBooks.map(BookRecord::id))

        books.value = listOf(book("1", "Dune", favorite = true), book("2", "Solaris", favorite = true))
        runCurrent()
        assertEquals(listOf("2"), model.state.value.visibleBooks.map(BookRecord::id))
        collect.cancel()
    }

    @Test fun searchAndFavoriteSelectionRestoreFromSavedStateAfterRecreation() = runTest {
        val books = MutableStateFlow(listOf(book("1", "Dune", favorite = true), book("2", "Solaris")))
        val outcomes = MutableStateFlow<SyncOutcome?>(null)
        val first = LibraryViewModel(SavedStateHandle(), books, outcomes, backgroundScope)
        val firstCollect = backgroundScope.launch { first.state.collect {} }
        runCurrent()
        first.search("dune")
        first.toggleFavorites()
        runCurrent()

        val restoredHandle = SavedStateHandle(mapOf(
            "library.search" to "dune",
            "library.favoritesOnly" to true,
        ))
        val recreated = LibraryViewModel(restoredHandle, books, outcomes, backgroundScope)
        val recreatedCollect = backgroundScope.launch { recreated.state.collect {} }
        runCurrent()

        assertEquals("dune", recreated.state.value.searchQuery)
        assertEquals(true, recreated.state.value.favoritesOnly)
        assertEquals(listOf("1"), recreated.state.value.visibleBooks.map(BookRecord::id))
        firstCollect.cancel()
        recreatedCollect.cancel()
    }

    private fun book(id: String, title: String, favorite: Boolean = false) = BookRecord(
        id = id,
        title = title,
        fileName = "$id.txt",
        format = "txt",
        addedAt = id.toDouble(),
        isBookmarked = favorite,
        modifiedAt = id.toDouble(),
    )
}
