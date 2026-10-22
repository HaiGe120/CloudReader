package io.github.haige120.cloudreader

import android.app.Activity
import android.content.Intent
import android.widget.Toast
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.compose.setContent
import androidx.activity.result.IntentSenderRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.size
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.MenuBook
import androidx.compose.material.icons.filled.AutoAwesome
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.NavigationRail
import androidx.compose.material3.NavigationRailItem
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Surface
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.layout.positionInWindow
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.unit.dp
import androidx.fragment.app.FragmentActivity
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.lifecycle.viewmodel.initializer
import androidx.lifecycle.viewmodel.viewModelFactory
import androidx.window.layout.FoldingFeature
import androidx.window.layout.WindowInfoTracker
import io.github.haige120.cloudreader.ai.AIProfile
import io.github.haige120.cloudreader.domain.BookRecord
import io.github.haige120.cloudreader.sync.OAuthConnector
import io.github.haige120.cloudreader.sync.SyncTrigger
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.debounce
import kotlinx.coroutines.flow.drop
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.FlowPreview
import kotlinx.coroutines.launch

private val Cream = Color(0xFFF7F3E9)
private val Paper = Color(0xFFFFFDF7)
private val Ink = Color(0xFF292621)
private val Leaf = Color(0xFF536D59)
private val Brown = Color(0xFF80654B)

class MainActivity : FragmentActivity() {
    private val cloudApp get() = application as CloudReaderApp

    override fun onCreate(savedInstanceState: android.os.Bundle?) {
        super.onCreate(savedInstanceState)
        setContent { CloudReaderRoot(this, cloudApp) }
    }

    override fun onStart() {
        super.onStart()
        cloudApp.applicationScope.launch {
            cloudApp.ready.await()
            cloudApp.requestSync(SyncTrigger.FOREGROUND)
        }
    }
}

private enum class MainDestination { LIBRARY, ASSISTANT, SETTINGS }

@Composable
@OptIn(FlowPreview::class)
private fun CloudReaderRoot(activity: FragmentActivity, app: CloudReaderApp) {
    var destination by rememberSaveable { mutableStateOf(MainDestination.LIBRARY) }
    var readerContext by remember { mutableStateOf<ReaderContext?>(null) }
    var message by remember { mutableStateOf<String?>(null) }
    val scope = rememberCoroutineScope()
    val context = LocalContext.current
    val snackbarHostState = remember { SnackbarHostState() }
    val googleConnector = remember(app) { OAuthConnector(app, app.preferences, app.vault) }
    val googleConnection: GoogleDriveConnectionViewModel = viewModel(factory = remember(app) {
        viewModelFactory {
            initializer { GoogleDriveConnectionViewModel(saveToken = { token -> googleConnector.connectGoogle(token) }) }
        }
    })
    val googleState by googleConnection.state.collectAsStateWithLifecycle()
    val syncOutcome by app.syncOutcome.collectAsState()
    var separatingHinge by remember { mutableStateOf<android.graphics.Rect?>(null) }
    var rootWindowOffset by remember { mutableStateOf(Offset.Zero) }

    LaunchedEffect(activity) {
        WindowInfoTracker.getOrCreate(activity).windowLayoutInfo(activity).collect { info ->
            separatingHinge = info.displayFeatures.filterIsInstance<FoldingFeature>()
                .firstOrNull { it.isSeparating }?.bounds
        }
    }

    LaunchedEffect(message) {
        val next = message ?: return@LaunchedEffect
        snackbarHostState.showSnackbar(next)
        message = null
    }
    LaunchedEffect(syncOutcome) {
        val outcome = syncOutcome ?: return@LaunchedEffect
        if (outcome.failed.isNotEmpty()) {
            val names = mapOf("googleDrive" to "Google Drive", "dropbox" to "Dropbox", "pCloud" to "pCloud", "webDAV" to "WebDAV", "sftp" to "SFTP", "filesFolder" to "Folder")
            snackbarHostState.showSnackbar(outcome.failed.entries.joinToString("\n") { (provider, failure) -> "${names[provider] ?: provider}: $failure" })
        }
    }

    val importLauncher = rememberLauncherForActivityResult(ActivityResultContracts.OpenMultipleDocuments()) { uris ->
        if (uris.isNotEmpty()) scope.launch {
            val (imported, rejected) = app.library.importUris(uris)
            Toast.makeText(context, "Imported $imported · skipped $rejected", Toast.LENGTH_SHORT).show()
        }
    }
    val folderLauncher = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocumentTree()) { uri ->
        if (uri != null) scope.launch {
            runCatching {
                activity.contentResolver.takePersistableUriPermission(uri, Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
                app.preferences.set("folder.treeUri", uri.toString())
                app.preferences.selectProvider("filesFolder", true)
            }.onSuccess { Toast.makeText(context, "Folder sync connected", Toast.LENGTH_SHORT).show() }
                .onFailure { Toast.makeText(context, it.localizedMessage ?: "Folder access failed", Toast.LENGTH_LONG).show() }
        }
    }
    val googleLauncher = rememberLauncherForActivityResult(ActivityResultContracts.StartIntentSenderForResult()) { result ->
        googleConnection.completeAsync(
            cancelled = result.resultCode == Activity.RESULT_CANCELED,
            hasData = result.data != null,
        ) {
            googleConnector.finishGoogle(result.data)
        }
    }
    val pdfLauncher = rememberLauncherForActivityResult(ActivityResultContracts.StartActivityForResult()) { result ->
        val selected = result.data?.getStringExtra(PdfReaderActivity.EXTRA_SELECTED_TEXT)?.takeIf(String::isNotBlank)
        if (selected != null) {
            scope.launch {
                val resolved = result.data?.getStringExtra(PdfReaderActivity.EXTRA_BOOK_ID)?.let { id ->
                    app.library.books.first().firstOrNull { book -> book.id == id }
                }
                readerContext = ReaderContext(resolved, selected, null)
                destination = MainDestination.ASSISTANT
            }
        }
    }

    LaunchedEffect(Unit) {
        combine(app.library.books, app.library.conversations) { books, chats ->
            books.map { it.id to it.modifiedAt } + chats.map { it.id to it.modifiedAt }
        }.drop(1).debounce(2_000).collect {
            app.ready.await()
            app.requestSync(SyncTrigger.LOCAL_CHANGE)
        }
    }

    MaterialTheme(
        colorScheme = lightColorScheme(
            primary = Leaf, onPrimary = Color.White, secondary = Brown, background = Cream,
            surface = Paper, onSurface = Ink, onBackground = Ink,
        ),
        typography = MaterialTheme.typography,
    ) {
        Surface(Modifier.fillMaxSize(), color = Cream) {
            BoxWithConstraints(Modifier.fillMaxSize().onGloballyPositioned { rootWindowOffset = it.positionInWindow() }) {
                val expanded = maxWidth >= 840.dp
                val textBook = readerContext?.book?.takeIf { it.format == "txt" && destination != MainDestination.ASSISTANT }
                if (textBook != null) {
                    TextBookScreen(
                        app = app,
                        book = textBook,
                        onClose = { readerContext = null },
                        onAsk = { excerpt ->
                            readerContext = ReaderContext(textBook, excerpt, null)
                            destination = MainDestination.ASSISTANT
                        },
                    )
                } else {
                    Scaffold(
                        containerColor = Cream,
                        contentWindowInsets = WindowInsets.safeDrawing,
                        snackbarHost = { SnackbarHost(snackbarHostState) },
                        bottomBar = {
                            if (!expanded) {
                                NavigationBar(containerColor = Paper) {
                                    MainDestination.entries.forEach { item ->
                                        NavigationBarItem(
                                            selected = destination == item,
                                            onClick = { destination = item },
                                            icon = { DestinationIcon(item) },
                                            label = { androidx.compose.material3.Text(item.label()) },
                                        )
                                    }
                                }
                            }
                        },
                    ) { insets ->
                        Row(Modifier.fillMaxSize().padding(insets)) {
                            if (expanded) {
                                NavigationRail(containerColor = Cream) {
                                    MainDestination.entries.forEach { item ->
                                        NavigationRailItem(
                                            selected = destination == item,
                                            onClick = { destination = item },
                                            icon = { DestinationIcon(item) },
                                            label = { androidx.compose.material3.Text(item.label()) },
                                            alwaysShowLabel = true,
                                        )
                                    }
                                }
                            }
                            Column(Modifier.fillMaxSize().weight(1f)) {
                                when (destination) {
                                    MainDestination.LIBRARY -> LibraryScreen(
                                        app = app,
                                        actions = LibraryScreenActions(
                                          onSync = { scope.launch { app.requestSync(SyncTrigger.MANUAL) } },
                                          onImport = { importLauncher.launch(arrayOf("text/plain", "application/pdf", "application/epub+zip", "application/octet-stream")) },
                                          onOpen = { book ->
                                            when (book.format.lowercase()) {
                                                "txt" -> destination = MainDestination.LIBRARY.also { readerContext = ReaderContext(book, null, null) }
                                                "pdf" -> pdfLauncher.launch(Intent(activity, PdfReaderActivity::class.java).apply {
                                                    putExtra(PdfReaderActivity.EXTRA_BOOK_ID, book.id)
                                                })
                                                "epub" -> activity.startActivity(Intent(activity, EpubReaderActivity::class.java).apply {
                                                    putExtra(EpubReaderActivity.EXTRA_BOOK_ID, book.id)
                                                })
                                                else -> Toast.makeText(context, "Reader coming later for ${book.format.uppercase()}", Toast.LENGTH_SHORT).show()
                                            }
                                          },
                                          onAsk = { book, excerpt ->
                                            readerContext = ReaderContext(book, excerpt, null)
                                            destination = MainDestination.ASSISTANT
                                          },
                                          onRemove = { book -> scope.launch { app.library.remove(book) } },
                                          onToggleFavorite = { book -> scope.launch { app.library.bookmark(book) } },
                                        ),
                                    )
                                    MainDestination.ASSISTANT -> AssistantScreen(
                                        app = app, context = readerContext,
                                        onContextConsumed = { readerContext = null },
                                        onMessage = { message = it },
                                    )
                                    MainDestination.SETTINGS -> SettingsScreen(
                                        activity = activity,
                                        app = app,
                                        onPickFolder = { folderLauncher.launch(null) },
                                        googleConnection = googleState,
                                        onConnectGoogle = {
                                            googleConnection.connectAsync { onToken, onError ->
                                                googleConnector.authorizeGoogle(
                                                    { sender -> googleLauncher.launch(IntentSenderRequest.Builder(sender).build()) },
                                                    onToken, onError,
                                                )
                                            }
                                        },
                                        onGoogleCredentialsSaved = { googleConnection.consumeMessage() },
                                        onMessage = { message = it },
                                    )
                                }
                            }
                        }
                    }
                }
                separatingHinge?.let { hinge ->
                    val density = androidx.compose.ui.platform.LocalDensity.current
                    val x = with(density) { (hinge.left - rootWindowOffset.x).toDp() }
                    val y = with(density) { (hinge.top - rootWindowOffset.y).toDp() }
                    val width = with(density) { hinge.width().toDp() }
                    val height = with(density) { hinge.height().toDp() }
                    androidx.compose.foundation.layout.Box(
                        Modifier.offset(x = x, y = y).size(width, height).background(Cream)
                    )
                }
            }
        }
    }
}

private fun MainDestination.label() = when (this) { MainDestination.LIBRARY -> "Library"; MainDestination.ASSISTANT -> "Ask AI"; MainDestination.SETTINGS -> "Settings" }

@Composable
private fun DestinationIcon(destination: MainDestination) {
    when (destination) {
        MainDestination.LIBRARY -> androidx.compose.material3.Icon(Icons.AutoMirrored.Filled.MenuBook, contentDescription = null)
        MainDestination.ASSISTANT -> androidx.compose.material3.Icon(Icons.Filled.AutoAwesome, contentDescription = null)
        MainDestination.SETTINGS -> androidx.compose.material3.Icon(Icons.Filled.Settings, contentDescription = null)
    }
}

data class ReaderContext(val book: BookRecord?, val selectedText: String?, val bookText: String?)

fun defaultAIProfile(settings: Map<String, String> = emptyMap()) = AIProfile(
    name = settings["ai.name"] ?: "My AI",
    protocol = settings["ai.protocol"] ?: "openAIResponses",
    endpoint = settings["ai.endpoint"] ?: "",
    model = settings["ai.model"] ?: "",
)
