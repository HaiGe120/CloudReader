package io.github.haige120.cloudreader.desktop

import androidx.compose.ui.window.Window
import androidx.compose.ui.window.application
import java.nio.file.Path

fun main() = application {
    val root = Path.of(System.getProperty("user.home"), ".cloudreader-desktop")
    val repository = FileLibraryRepository(root)
    Window(onCloseRequest = ::exitApplication, title = "CloudReader") {
        CloudReaderDesktopApp(repository, SwingFilePicker(), TxtContentReader())
    }
}
