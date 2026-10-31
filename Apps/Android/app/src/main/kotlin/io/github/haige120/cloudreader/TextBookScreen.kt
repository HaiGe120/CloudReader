package io.github.haige120.cloudreader

import android.app.Activity
import android.content.Context
import android.content.ContextWrapper
import android.graphics.Typeface
import android.view.GestureDetector
import android.view.MotionEvent
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.material.icons.filled.AutoAwesome
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextOverflow
import androidx.core.view.ViewCompat
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import android.view.ActionMode
import android.view.Menu
import android.view.MenuItem
import android.widget.ScrollView
import android.widget.TextView
import androidx.compose.foundation.background
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.pager.HorizontalPager
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Remove
import androidx.compose.material.icons.filled.Add
import androidx.compose.material3.FilterChip
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.snapshotFlow
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import io.github.haige120.cloudreader.domain.BookRecord
import io.github.haige120.cloudreader.data.toDomain
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver

private class ReaderViewState(var textSize: Float, var font: String, var theme: String, var fraction: Float, var restoring: Boolean = true, var content: String? = null)

@Composable
fun TextBookScreen(app: CloudReaderApp, book: BookRecord, onClose: () -> Unit, onAsk: (String) -> Unit) {
    val scope = rememberCoroutineScope()
    val lifecycleOwner = LocalLifecycleOwner.current
    var contents by remember(book.id) { mutableStateOf<String?>(null) }
    var error by remember(book.id) { mutableStateOf<String?>(null) }
    val fontSizeSetting by app.preferences.observe("reader.fontSize", "20").collectAsState(initial = "20")
    val fontSetting by app.preferences.observe("reader.font", "serif").collectAsState(initial = "serif")
    val themeSetting by app.preferences.observe("reader.theme", "system").collectAsState(initial = "system")
    val customBackground by app.preferences.observe("reader.customBackground", "#F8F4EB").collectAsState(initial = "#F8F4EB")
    val customForeground by app.preferences.observe("reader.customForeground", "#292621").collectAsState(initial = "#292621")
    val layoutSetting by app.preferences.observe("reader.layout", "scroll").collectAsState(initial = "scroll")
    val fontSize = fontSizeSetting.toFloatOrNull()?.coerceIn(14f, 38f) ?: 20f
    val readerSession = remember(book.id) {
        ReaderSession(book.id, app.applicationScope, ReaderProgressWriter { id, progress, location ->
            val current = app.database.libraryDao().book(id)?.toDomain() ?: return@ReaderProgressWriter
            app.library.progress(current, progress, location)
        })
    }
    fun flushProgress() { app.applicationScope.launch { readerSession.flush() } }
    var currentProgress by rememberSaveable(book.id) { mutableStateOf(book.progress) }
    var facingOffset by rememberSaveable(book.id) { mutableIntStateOf(book.localLocation?.substringAfter("txt:")?.substringBefore(':')?.toIntOrNull() ?: 0) }

    DisposableEffect(lifecycleOwner, book.id) {
        val observer = LifecycleEventObserver { _, event -> if (event == Lifecycle.Event.ON_STOP) flushProgress() }
        lifecycleOwner.lifecycle.addObserver(observer)
        onDispose {
            lifecycleOwner.lifecycle.removeObserver(observer)
            flushProgress()
        }
    }

    val restoredTextOffset = contents?.let { text ->
        validTextOffset(book.localLocation, text.length) ?: textOffsetForProgress(book.progress, text.length)
    }
    LaunchedEffect(contents, book.id) {
        val text = contents ?: return@LaunchedEffect
        val offset = validTextOffset(book.localLocation, text.length) ?: textOffsetForProgress(book.progress, text.length)
        facingOffset = offset
    }

    LaunchedEffect(book.id) {
        val file = app.library.fileFor(book)
        if (file == null) { error = "The local book file is missing."; return@LaunchedEffect }
        runCatching { withContext(Dispatchers.IO) { decodeText(file.readBytes()) } }
            .onSuccess { contents = it }
            .onFailure { error = "This text file could not be opened: ${it.localizedMessage ?: "unknown error"}" }
        app.library.opened(book)
    }

    TextReaderContent(
        bookId = book.id,
        title = book.title,
        contents = contents,
        error = error,
        progress = currentProgress,
        initialProgress = book.progress,
        initialOffset = restoredTextOffset ?: 0,
        facingOffset = facingOffset,
        appearance = TextReaderAppearance(fontSize, fontSetting, themeSetting, customBackground, customForeground, layoutSetting),
        onSettingChanged = { key, value -> scope.launch { app.preferences.set(key, value) } },
        onProgress = { fraction, offset ->
            currentProgress = fraction
            facingOffset = offset
            readerSession.checkpoint(fraction, "txt:$offset:utf16")
        },
        onClose = { flushProgress(); onClose() },
        onAsk = onAsk,
    )
}

internal data class TextReaderAppearance(
    val fontSize: Float = 20f,
    val font: String = "serif",
    val theme: String = "system",
    val customBackground: String = "#F8F4EB",
    val customForeground: String = "#292621",
    val layout: String = "scroll",
)

// This content boundary also lets reader interactions be verified without opening a real library.
@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun TextReaderContent(
    bookId: String,
    title: String,
    contents: String?,
    error: String? = null,
    progress: Double = 0.0,
    initialProgress: Double = 0.0,
    initialOffset: Int = 0,
    facingOffset: Int = 0,
    appearance: TextReaderAppearance = TextReaderAppearance(),
    onSettingChanged: (String, String) -> Unit,
    onProgress: (Double, Int) -> Unit,
    onClose: () -> Unit,
    onAsk: (String) -> Unit,
) {
    var controlsVisible by rememberSaveable(bookId) { mutableStateOf(true) }
    var appearanceVisible by rememberSaveable(bookId) { mutableStateOf(false) }
    val readerTheme = if (appearance.theme == "system" && isSystemInDarkTheme()) "dark" else appearance.theme
    val paper = Color(readerBackground(readerTheme, appearance.customBackground))
    val ink = Color(readerForeground(readerTheme, appearance.customForeground))
    val currentToggle by rememberUpdatedState { controlsVisible = !controlsVisible }
    val currentAsk by rememberUpdatedState(onAsk)
    BackHandler { onClose() }
    ReaderSystemBars(controlsVisible)

    Surface(Modifier.fillMaxSize(), color = paper, contentColor = ink) {
        Box(Modifier.fillMaxSize().windowInsetsPadding(WindowInsets.safeDrawing)) {
            Column(Modifier.fillMaxSize()) {
                if (controlsVisible) {
                    Row(Modifier.fillMaxWidth().padding(horizontal = 4.dp), verticalAlignment = Alignment.CenterVertically) {
                        IconButton(onClick = onClose) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "Close book") }
                        Column(Modifier.weight(1f)) {
                            Text(title, fontFamily = FontFamily.Serif, fontSize = 16.sp, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis)
                            Text("${(progress * 100).toInt()}% read", style = MaterialTheme.typography.labelSmall, color = ink.copy(alpha = 0.7f))
                        }
                        IconButton(onClick = { onAsk("") }) { Icon(Icons.Filled.AutoAwesome, "Ask AI about this book") }
                        IconButton(onClick = { appearanceVisible = true }, modifier = Modifier.semantics { contentDescription = "Reading appearance" }) {
                            Text("Aa", fontSize = 18.sp, fontWeight = FontWeight.Medium)
                        }
                        IconButton(onClick = { controlsVisible = false }) { Icon(Icons.Filled.Close, "Hide reading controls") }
                    }
                }
                Box(Modifier.weight(1f).fillMaxWidth()) {
                    when {
                        contents != null && appearance.layout == "facing" -> FacingTextPages(
                            text = contents, offset = facingOffset, fontSize = appearance.fontSize, font = appearance.font, theme = readerTheme,
                            customBackground = appearance.customBackground, customForeground = appearance.customForeground,
                            controlsVisible = controlsVisible,
                            onPageChanged = { offset -> onProgress((offset.toDouble() / contents.length.coerceAtLeast(1)).coerceIn(0.0, 1.0), offset) },
                            onAsk = { currentAsk(it) },
                            onContentTap = { currentToggle() },
                        )
                        contents != null -> SingleScrollText(
                            text = contents, initialOffset = initialOffset, fontSize = appearance.fontSize, font = appearance.font, theme = readerTheme,
                            customBackground = appearance.customBackground, customForeground = appearance.customForeground,
                            initialProgress = initialProgress,
                            onScroll = onProgress,
                            onAsk = { currentAsk(it) },
                            onContentTap = { currentToggle() },
                        )
                        error != null -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) { Text(error, color = Color(0xFF9B4138), modifier = Modifier.padding(24.dp)) }
                        else -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) { Text("Opening book…", color = ink.copy(alpha = 0.7f)) }
                    }
                }
            }
            if (!controlsVisible) {
                Surface(
                    modifier = Modifier.align(Alignment.TopEnd).padding(8.dp),
                    shape = RoundedCornerShape(24.dp),
                    color = paper.copy(alpha = 0.94f),
                    contentColor = ink,
                    tonalElevation = 2.dp,
                ) {
                    TextButton(onClick = { controlsVisible = true }) { Text("Show controls") }
                }
            }
        }
    }
    if (appearanceVisible) {
        ModalBottomSheet(onDismissRequest = { appearanceVisible = false }, sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)) {
            Column(Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).padding(horizontal = 20.dp).padding(bottom = 24.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.SpaceBetween) {
                    Text("Reading appearance", style = MaterialTheme.typography.titleLarge)
                    TextButton(onClick = { appearanceVisible = false }) { Text("Done") }
                }
                Text("Page layout", style = MaterialTheme.typography.titleSmall)
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    FilterChip(selected = appearance.layout != "facing", onClick = { onSettingChanged("reader.layout", "scroll") }, label = { Text("Scrolling") })
                    FilterChip(selected = appearance.layout == "facing", onClick = { onSettingChanged("reader.layout", "facing") }, label = { Text("Facing pages") })
                }
                Text("Pages turn horizontally, with two pages on wide screens.", style = MaterialTheme.typography.bodySmall)
                Text("Page color", style = MaterialTheme.typography.titleSmall)
                Row(Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(7.dp)) {
                    listOf("system", "light", "sepia", "dark", "custom").forEach { theme ->
                        FilterChip(selected = appearance.theme == theme, onClick = { onSettingChanged("reader.theme", theme) }, label = { Text(theme.replaceFirstChar(Char::uppercase)) })
                    }
                }
                if (appearance.theme == "custom") {
                    Text("Paper", style = MaterialTheme.typography.labelMedium)
                    Row(Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(7.dp)) {
                        listOf("#F8F4EB", "#FFFEF8", "#E6E8D8", "#F2DEC2", "#232322").forEach { value ->
                            ColorChoice(value, appearance.customBackground == value) { onSettingChanged("reader.customBackground", value) }
                        }
                    }
                    Text("Ink", style = MaterialTheme.typography.labelMedium)
                    Row(Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(7.dp)) {
                        listOf("#292621", "#3C332A", "#1D3A2A", "#F2EFE8", "#FFFFFF").forEach { value ->
                            ColorChoice(value, appearance.customForeground == value) { onSettingChanged("reader.customForeground", value) }
                        }
                    }
                }
                Text("Typography", style = MaterialTheme.typography.titleSmall)
                Row(Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    listOf("serif" to "Serif", "sans" to "Sans", "mono" to "Mono").forEach { (value, label) ->
                        FilterChip(selected = appearance.font == value, onClick = { onSettingChanged("reader.font", value) }, label = { Text(label) })
                    }
                }
                Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.SpaceBetween) {
                    Text("Text size", style = MaterialTheme.typography.bodyMedium)
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        IconButton(onClick = { onSettingChanged("reader.fontSize", (appearance.fontSize - 1f).coerceAtLeast(14f).toInt().toString()) }) { Icon(Icons.Filled.Remove, "Smaller text") }
                        Text("${appearance.fontSize.toInt()} pt")
                        IconButton(onClick = { onSettingChanged("reader.fontSize", (appearance.fontSize + 1f).coerceAtMost(38f).toInt().toString()) }) { Icon(Icons.Filled.Add, "Larger text") }
                    }
                }
            }
        }
    }
}

@Composable
private fun ReaderSystemBars(controlsVisible: Boolean) {
    val context = LocalContext.current
    val activity = remember(context) {
        var candidate: Context = context
        while (candidate is ContextWrapper && candidate !is Activity) candidate = candidate.baseContext
        candidate as? Activity
    }
    val window = activity?.window ?: return
    DisposableEffect(window) {
        val insets = ViewCompat.getRootWindowInsets(window.decorView)
        val statusVisible = insets?.isVisible(WindowInsetsCompat.Type.statusBars()) ?: true
        val navigationVisible = insets?.isVisible(WindowInsetsCompat.Type.navigationBars()) ?: true
        val controller = WindowCompat.getInsetsController(window, window.decorView)
        val behavior = controller.systemBarsBehavior
        onDispose {
            controller.systemBarsBehavior = behavior
            if (statusVisible) controller.show(WindowInsetsCompat.Type.statusBars()) else controller.hide(WindowInsetsCompat.Type.statusBars())
            if (navigationVisible) controller.show(WindowInsetsCompat.Type.navigationBars()) else controller.hide(WindowInsetsCompat.Type.navigationBars())
        }
    }
    LaunchedEffect(window, controlsVisible) {
        val controller = WindowCompat.getInsetsController(window, window.decorView)
        if (controlsVisible) controller.show(WindowInsetsCompat.Type.systemBars())
        else {
            controller.systemBarsBehavior = WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
            controller.hide(WindowInsetsCompat.Type.systemBars())
        }
    }
}

@Composable
private fun SingleScrollText(text: String, initialOffset: Int, fontSize: Float, font: String, theme: String, customBackground: String, customForeground: String, initialProgress: Double, onScroll: (Double, Int) -> Unit, onAsk: (String) -> Unit, onContentTap: () -> Unit) {
    AndroidView(
        modifier = Modifier.fillMaxSize().padding(horizontal = 18.dp, vertical = 8.dp),
        factory = { ctx ->
            val scroll = ScrollView(ctx).apply { isFillViewport = true; overScrollMode = ScrollView.OVER_SCROLL_NEVER }
            val view = selectableText(ctx, onAsk, onContentTap).apply { setPadding(8.dpInt(ctx), 8.dpInt(ctx), 8.dpInt(ctx), 28.dpInt(ctx)) }
            scroll.addView(view)
            scroll.tag = ReaderViewState(fontSize, font, theme, initialProgress.toFloat())
            scroll.setOnScrollChangeListener { viewScroll, _, scrollY, _, _ ->
                val scrollView = viewScroll as ScrollView
                val total = (scrollView.getChildAt(0)?.height ?: 0) - scrollView.height
                if (total > 0) {
                    val state = scrollView.tag as? ReaderViewState
                    if (state?.restoring == true) return@setOnScrollChangeListener
                    val fraction = (scrollY.toFloat() / total).coerceIn(0f, 1f)
                    state?.fraction = fraction
                    val layout = view.layout
                    val line = if (layout != null) layout.getLineForVertical(scrollY.coerceIn(0, layout.height - 1)) else 0
                    onScroll(fraction.toDouble(), layout?.getLineStart(line) ?: (fraction * text.length).toInt())
                }
            }
            scroll
        },
        update = { view ->
            val scroll = view as? ScrollView ?: return@AndroidView
            val textView = scroll.getChildAt(0) as TextView
            val state = scroll.tag as? ReaderViewState
            val oldFraction = state?.fraction ?: initialProgress.toFloat()
            val needsRestore = state == null || state.restoring || state.content !== text || state.textSize != fontSize || state.font != font
            if (state?.content !== text) textView.text = text
            textView.textSize = fontSize
            textView.typeface = typeface(font)
            textView.setTextColor(readerForeground(theme, customForeground))
            textView.setBackgroundColor(readerBackground(theme, customBackground))
            scroll.setBackgroundColor(readerBackground(theme, customBackground))
            if (needsRestore) scroll.post {
                val total = (scroll.getChildAt(0)?.height ?: 0) - scroll.height
                if (total > 0) {
                    val layout = textView.layout
                    val targetY = if (state?.restoring == true && layout != null) {
                        layout.getLineTop(layout.getLineForOffset(initialOffset.coerceIn(0, text.length)))
                    } else (oldFraction.coerceIn(0f, 1f) * total).toInt()
                    scroll.scrollTo(0, targetY.coerceIn(0, total))
                }
                state?.restoring = false
            }
            if (state == null) scroll.tag = ReaderViewState(fontSize, font, theme, oldFraction)
            else { state.textSize = fontSize; state.font = font; state.theme = theme; state.content = text }
        },
    )
}

@Composable
private fun FacingTextPages(text: String, offset: Int, fontSize: Float, font: String, theme: String, customBackground: String, customForeground: String, controlsVisible: Boolean, onPageChanged: (Int) -> Unit, onAsk: (String) -> Unit, onContentTap: () -> Unit) {
    val wide = androidx.compose.ui.platform.LocalConfiguration.current.smallestScreenWidthDp >= 600
    val scope = rememberCoroutineScope()
    val reportPageChanged by rememberUpdatedState(onPageChanged)
    BoxWithConstraints(Modifier.fillMaxSize()) {
        val columns = if (wide) 2 else 1
        val sample = text.take(4000)
        val cjkRatio = if (sample.isEmpty()) 0.0 else sample.count { it.code in 0x2E80..0x9FFF || it.code in 0xF900..0xFAFF }.toDouble() / sample.length
        val averageCharWidth = when { cjkRatio > 0.20 -> 0.95f; font == "mono" -> 0.62f; else -> 0.54f }
        val lineWidth = (maxWidth.value / columns - 42f).coerceAtLeast(120f)
        val textHeight = (maxHeight.value - 54f).coerceAtLeast(220f)
        val charsPerLine = (lineWidth / (fontSize * averageCharWidth)).toInt().coerceAtLeast(8)
        val visibleLines = (textHeight / (fontSize * 1.55f)).toInt().coerceAtLeast(10)
        val pageChars = (charsPerLine * visibleLines).coerceAtLeast(120)
        val pageStarts = remember(text, pageChars) { pageStartOffsets(text, pageChars) }
        val pageCount = pageStarts.size.coerceAtLeast(1)
        val spreadCount = if (wide) (pageCount + 1) / 2 else pageCount
        fun spreadForOffset(value: Int): Int {
            val index = pageStarts.indexOfLast { it <= value.coerceAtLeast(0) }.coerceAtLeast(0)
            return (if (wide) index / 2 else index).coerceIn(0, (spreadCount - 1).coerceAtLeast(0))
        }
        val pager = rememberPagerState(initialPage = spreadForOffset(offset), pageCount = { spreadCount })
        LaunchedEffect(pager, pageStarts, wide) {
            // BoxWithConstraints can start this effect inside its parent's measure pass.
            // Schedule the new position for the next measure instead of forcing a nested one.
            pager.requestScrollToPage(spreadForOffset(offset))
            // Start observing only after remapping the saved text anchor. A separate effect
            // could publish the old page index against new page boundaries during a resize.
            snapshotFlow { pager.currentPage }.collect { page ->
                val first = if (wide) page * 2 else page
                reportPageChanged(pageStarts.getOrElse(first) { 0 })
            }
        }
        Column(Modifier.fillMaxSize(), verticalArrangement = Arrangement.SpaceBetween) {
            HorizontalPager(state = pager, modifier = Modifier.weight(1f).fillMaxWidth()) { spread ->
                val first = if (wide) spread * 2 else spread
                Row(Modifier.fillMaxSize().padding(horizontal = 13.dp, vertical = 6.dp), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    repeat(if (wide) 2 else 1) { column ->
                        val index = first + column
                        val start = pageStarts.getOrElse(index) { text.length }
                        val end = pageStarts.getOrElse(index + 1) { text.length }
                        val passage = text.substring(start.coerceAtMost(text.length), end.coerceAtMost(text.length))
                        AndroidView(
                            modifier = Modifier.weight(1f).fillMaxSize().background(Color(readerBackground(theme, customBackground)), RoundedCornerShape(8.dp)).padding(12.dp),
                            factory = { ctx -> selectableText(ctx, onAsk, onContentTap) },
                            update = { tv -> if (tv.text.toString() != passage) tv.text = passage; tv.textSize = fontSize; tv.typeface = typeface(font); tv.setTextColor(readerForeground(theme, customForeground)); tv.setBackgroundColor(readerBackground(theme, customBackground)) },
                        )
                    }
                }
            }
            if (controlsVisible) Row(Modifier.fillMaxWidth().padding(horizontal = 22.dp, vertical = 8.dp), horizontalArrangement = Arrangement.SpaceBetween, verticalAlignment = Alignment.CenterVertically) {
                TextButton(onClick = { if (pager.currentPage > 0) scope.launch { pager.animateScrollToPage(pager.currentPage - 1) } }, enabled = pager.currentPage > 0) { Text("Previous") }
                Text("Spread ${pager.currentPage + 1} of $spreadCount", style = MaterialTheme.typography.labelMedium)
                TextButton(onClick = { if (pager.currentPage < spreadCount - 1) scope.launch { pager.animateScrollToPage(pager.currentPage + 1) } }, enabled = pager.currentPage < spreadCount - 1) { Text("Next") }
            }
        }
    }
}

internal fun pageStartOffsets(text: String, targetSize: Int): List<Int> {
    if (text.isEmpty()) return listOf(0)
    val starts = mutableListOf(0)
    val breaks = charArrayOf('\n', ' ', '\t', '\r')
    var start = 0
    while (start < text.length) {
        var end = (start + targetSize).coerceAtMost(text.length)
        if (end < text.length) {
            val boundary = text.lastIndexOfAny(breaks, end - 1)
            if (boundary > start + targetSize * 0.7) end = boundary + 1
        }
        if (end < text.length && end > 0 && Character.isHighSurrogate(text[end - 1]) && Character.isLowSurrogate(text[end])) end--
        if (end <= start) end = (start + targetSize).coerceAtMost(text.length)
        start = end
        starts += start
    }
    starts.removeAt(starts.lastIndex)
    return starts
}

@Composable
private fun ColorChoice(value: String, selected: Boolean, onClick: () -> Unit) {
    FilterChip(selected = selected, onClick = onClick, label = {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(5.dp)) {
            Box(Modifier.size(16.dp).background(Color(android.graphics.Color.parseColor(value)), RoundedCornerShape(50)))
            Text(value.removePrefix("#"), style = MaterialTheme.typography.labelSmall)
        }
    })
}

private fun selectableText(context: android.content.Context, onAsk: (String) -> Unit, onContentTap: () -> Unit): TextView = TextView(context).apply {
    // Observe taps without consuming events: TextView keeps native long-press selection,
    // ScrollView keeps vertical drags, and the pager keeps horizontal swipes.
    var selectionAtDown = false
    var selecting = false
    val detector = GestureDetector(context, object : GestureDetector.SimpleOnGestureListener() {
        override fun onDown(event: MotionEvent): Boolean {
            selectionAtDown = hasSelection() || selecting
            return true
        }
        override fun onSingleTapConfirmed(event: MotionEvent): Boolean {
            if (!selectionAtDown && !hasSelection() && !selecting) onContentTap()
            return false
        }
    })
    setOnTouchListener { _, event -> detector.onTouchEvent(event); false }
    setTextIsSelectable(true)
    textSize = 20f
    setTextColor(Color(0xFF292621).toArgbCompat())
    setLineSpacing(7.dpInt(context).toFloat(), 1.15f)
    setPadding(10.dpInt(context), 10.dpInt(context), 10.dpInt(context), 10.dpInt(context))
    customSelectionActionModeCallback = object : ActionMode.Callback {
        override fun onCreateActionMode(mode: ActionMode, menu: Menu): Boolean {
            selecting = true
            menu.add(0, 1901, 0, "Ask CloudReader").setShowAsAction(MenuItem.SHOW_AS_ACTION_IF_ROOM)
            return true
        }
        override fun onPrepareActionMode(mode: ActionMode, menu: Menu) = false
        override fun onActionItemClicked(mode: ActionMode, item: MenuItem): Boolean {
            if (item.itemId != 1901) return false
            val start = selectionStart.coerceAtLeast(0); val end = selectionEnd.coerceAtLeast(start)
            val excerpt = text.subSequence(start, end).toString().take(18_000).trim()
            if (excerpt.isNotEmpty()) onAsk(excerpt)
            mode.finish()
            return true
        }
        override fun onDestroyActionMode(mode: ActionMode) { selecting = false }
    }
}

internal fun decodeText(bytes: ByteArray): String = when {
    bytes.size >= 2 && bytes[0] == 0xFF.toByte() && bytes[1] == 0xFE.toByte() -> String(bytes, 2, bytes.size - 2, Charsets.UTF_16LE)
    bytes.size >= 2 && bytes[0] == 0xFE.toByte() && bytes[1] == 0xFF.toByte() -> String(bytes, 2, bytes.size - 2, Charsets.UTF_16BE)
    bytes.size >= 3 && bytes[0] == 0xEF.toByte() && bytes[1] == 0xBB.toByte() && bytes[2] == 0xBF.toByte() -> String(bytes, 3, bytes.size - 3, Charsets.UTF_8)
    else -> String(bytes, Charsets.UTF_8)
}

private fun typeface(font: String): Typeface = when (font) { "sans" -> Typeface.SANS_SERIF; "mono" -> Typeface.MONOSPACE; else -> Typeface.SERIF }
private fun readerBackground(theme: String, custom: String = "#F8F4EB"): Int = when (theme) {
    "dark" -> 0xFF232322.toInt()
    "sepia" -> 0xFFECE1CB.toInt()
    "custom" -> runCatching { android.graphics.Color.parseColor(custom) }.getOrDefault(0xFFF8F4EB.toInt())
    "light" -> 0xFFFFFDF8.toInt()
    else -> 0xFFF8F4EB.toInt()
}
private fun readerForeground(theme: String, custom: String = "#292621"): Int = when (theme) {
    "dark" -> 0xFFE5E1D8.toInt()
    "custom" -> runCatching { android.graphics.Color.parseColor(custom) }.getOrDefault(0xFF292621.toInt())
    else -> 0xFF292621.toInt()
}
private fun Color.toArgbCompat(): Int = android.graphics.Color.argb((alpha * 255).toInt(), (red * 255).toInt(), (green * 255).toInt(), (blue * 255).toInt())
private fun Int.dpInt(context: android.content.Context) = (this * context.resources.displayMetrics.density).toInt()
private fun androidx.compose.ui.unit.Dp.dpInt(context: android.content.Context) = (value * context.resources.displayMetrics.density).toInt()
