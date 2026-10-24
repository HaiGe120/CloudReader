package io.github.haige120.cloudreader.desktop

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.Button
import androidx.compose.material.MaterialTheme
import androidx.compose.material.Surface
import androidx.compose.material.Text
import androidx.compose.material.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import java.awt.FileDialog
import java.awt.Frame
import java.nio.file.Path

class SwingFilePicker : FilePicker {
    override fun pickBook(): Path? {
        val dialog = FileDialog(null as Frame?, "Import a book", FileDialog.LOAD).apply {
            filenameFilter = java.io.FilenameFilter { _, name ->
                listOf("txt", "pdf", "epub", "fb2", "cbz", "cbr", "mobi", "azw3")
                    .any { name.endsWith(".$it", ignoreCase = true) }
            }
            isVisible = true
        }
        return dialog.file?.let { Path.of(dialog.directory, it) }
    }
}

@Composable
fun CloudReaderDesktopApp(repository: LibraryRepository, picker: FilePicker, reader: ContentReader) {
    var books by remember { mutableStateOf(repository.books()) }
    var selected by remember { mutableStateOf<BookRecord?>(null) }
    var message by remember { mutableStateOf("TXT is the only enabled reader in this feasibility slice.") }

    MaterialTheme {
        Surface(Modifier.fillMaxSize()) {
            Row(Modifier.fillMaxSize().padding(20.dp), horizontalArrangement = Arrangement.spacedBy(20.dp)) {
                Column(Modifier.fillMaxWidth(0.32f), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    Text("CloudReader", style = MaterialTheme.typography.h5)
                    Button(onClick = {
                        picker.pickBook()?.let { path ->
                            when (val result = repository.importBook(path)) {
                                is ImportResult.Imported -> { books = repository.books(); selected = result.book; message = "Imported ${result.book.title}" }
                                is ImportResult.Unsupported -> message = result.message
                                is ImportResult.Failed -> message = result.message
                            }
                        }
                    }) { Text("Import book") }
                    Text(message, style = MaterialTheme.typography.caption)
                    LazyColumn(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                        items(books, key = { it.id.value }) { book ->
                            TextButton(onClick = { selected = book }) {
                                Text(if (book.isFavorite) "★ ${book.title}" else book.title)
                            }
                        }
                    }
                }
                Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    val book = selected
                    if (book == null) {
                        Text("Select an imported book to read.")
                    } else if (!reader.supports(book.format)) {
                        Text("${book.format.name} reader is not available yet.")
                    } else {
                        reader.open(book).use { document ->
                            var resumeOffset by remember(book.id) { mutableStateOf(book.textOffset) }
                            Text(document.book.title, style = MaterialTheme.typography.h6)
                            Text("Resuming at UTF-16 offset $resumeOffset of ${document.text.length}", style = MaterialTheme.typography.caption)
                            Text(document.text.drop(resumeOffset).take(12_000))
                            Button(onClick = {
                                val updated = repository.updateProgress(book.id, document.text.length)
                                if (updated != null) {
                                    books = repository.books()
                                    selected = updated
                                    resumeOffset = updated.textOffset
                                    message = "Saved resume position for ${updated.title}"
                                }
                            }) { Text("Save resume position") }
                        }
                    }
                }
            }
        }
    }
}
