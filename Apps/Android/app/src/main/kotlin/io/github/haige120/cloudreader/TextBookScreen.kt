package io.github.haige120.cloudreader

import android.graphics.Typeface
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
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
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
import androidx.compose.material3.Button
import androidx.compose.material3.FilterChip
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalContext
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import io.github.haige120.cloudreader.data.BookRow
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

private data class ReaderViewState(val textSize: Float, val font: String, val theme: String, var fraction: Float)

@Composable
fun TextBookScreen(app: CloudReaderApp, book: BookRow, onClose: () -> Unit, onAsk: (String) -> Unit) {
    val configuration = LocalConfiguration.current
    val scope = rememberCoroutineScope()
    var contents by remember(book.id) { mutableStateOf<String?>(null) }
    var error by remember(book.id) { mutableStateOf<String?>(null) }
    val fontSizeSetting by app.preferences.observe("reader.fontSize", "20").collectAsState(initial = "20")
    val fontSetting by app.preferences.observe("reader.font", "serif").collectAsState(initial = "serif")
    val themeSetting by app.preferences.observe("reader.theme", "system").collectAsState(initial = "system")
    val customBackground by app.preferences.observe("reader.customBackground", "#F8F4EB").collectAsState(initial = "#F8F4EB")
    val customForeground by app.preferences.observe("reader.customForeground", "#292621").collectAsState(initial = "#292621")
    val layoutSetting by app.preferences.observe("reader.layout", "scroll").collectAsState(initial = "scroll")
    val fontSize = fontSizeSetting.toFloatOrNull()?.coerceIn(14f, 38f) ?: 20f
    var saveJob by remember { mutableStateOf<Job?>(null) }
    var facingOffset by rememberSaveable(book.id) { mutableIntStateOf(book.localLocation?.substringAfter("txt:")?.substringBefore(':')?.toIntOrNull() ?: 0) }
    val readerTheme = if (themeSetting == "system" && isSystemInDarkTheme()) "dark" else themeSetting

    LaunchedEffect(book.id) {
        val file = app.library.fileFor(book)
        if (file == null) { error = "The local book file is missing."; return@LaunchedEffect }
        runCatching { withContext(Dispatchers.IO) { decodeText(file.readBytes()) } }
            .onSuccess { contents = it }
            .onFailure { error = "This text file could not be opened: ${it.localizedMessage ?: "unknown error"}" }
        app.library.opened(book)
    }

    Surface(Modifier.fillMaxSize(), color = Color(readerBackground(readerTheme, customBackground))) {
        Column(Modifier.fillMaxSize()) {
            Row(Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 9.dp), verticalAlignment = Alignment.CenterVertically) {
                IconButton(onClick = onClose) { Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Close book") }
                Column(Modifier.weight(1f)) {
                    Text(book.title, fontFamily = FontFamily.Serif, fontSize = 18.sp, fontWeight = FontWeight.SemiBold, maxLines = 1)
                    Text("${(book.progress * 100).toInt()}% read", style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.secondary)
                }
                IconButton(onClick = { scope.launch { app.preferences.set("reader.fontSize", (fontSize - 1f).coerceAtLeast(14f).toInt().toString()) } }, content = { Icon(Icons.Filled.Remove, "Smaller text") })
                Text("${fontSize.toInt()}", style = MaterialTheme.typography.labelMedium)
                IconButton(onClick = { scope.launch { app.preferences.set("reader.fontSize", (fontSize + 1f).coerceAtMost(38f).toInt().toString()) } }, content = { Icon(Icons.Filled.Add, "Larger text") })
            }
            Row(Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()).padding(horizontal = 16.dp), horizontalArrangement = Arrangement.spacedBy(7.dp)) {
                listOf("system", "light", "sepia", "dark", "custom").forEach { theme ->
                    FilterChip(selected = themeSetting == theme, onClick = { scope.launch { app.preferences.set("reader.theme", theme) } }, label = { Text(theme.replaceFirstChar(Char::uppercase)) })
                }
            }
            if (themeSetting == "custom") {
                Row(Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()).padding(horizontal = 16.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(7.dp)) {
                    Text("Paper", style = MaterialTheme.typography.labelSmall)
                    listOf("#F8F4EB", "#FFFEF8", "#E6E8D8", "#F2DEC2", "#232322").forEach { value ->
                        ColorChoice(value, customBackground == value) { scope.launch { app.preferences.set("reader.customBackground", value) } }
                    }
                    Text("Ink", style = MaterialTheme.typography.labelSmall)
                    listOf("#292621", "#3C332A", "#1D3A2A", "#F2EFE8", "#FFFFFF").forEach { value ->
                        ColorChoice(value, customForeground == value) { scope.launch { app.preferences.set("reader.customForeground", value) } }
                    }
                }
            }
            Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.SpaceBetween) {
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    FilterChip(selected = fontSetting == "serif", onClick = { scope.launch { app.preferences.set("reader.font", "serif") } }, label = { Text("Serif") })
                    FilterChip(selected = fontSetting == "sans", onClick = { scope.launch { app.preferences.set("reader.font", "sans") } }, label = { Text("Sans") })
                    FilterChip(selected = fontSetting == "mono", onClick = { scope.launch { app.preferences.set("reader.font", "mono") } }, label = { Text("Mono") })
                }
                if ((configuration.smallestScreenWidthDp >= 600) || layoutSetting == "facing") {
                    FilterChip(selected = layoutSetting == "facing", onClick = {
                        scope.launch { app.preferences.set("reader.layout", if (layoutSetting == "facing") "scroll" else "facing") }
                    }, label = { Text(if (layoutSetting == "facing") "Facing pages" else "Pages") })
                }
            }
            when {
                contents != null -> {
                    if (layoutSetting == "facing") {
                        FacingTextPages(
                            text = contents!!, offset = facingOffset, fontSize = fontSize, font = fontSetting, theme = readerTheme,
                            customBackground = customBackground, customForeground = customForeground,
                            onPageChanged = { offset -> facingOffset = offset; saveJob?.cancel(); saveJob = scope.launch { app.library.progress(book, (offset.toDouble() / contents!!.length.coerceAtLeast(1)).coerceIn(0.0, 1.0), "txt:$offset:utf16") } },
                            onAsk = onAsk,
                        )
                    } else {
                        SingleScrollText(
                            text = contents!!, bookId = book.id, fontSize = fontSize, font = fontSetting, theme = readerTheme,
                            customBackground = customBackground, customForeground = customForeground,
                            initialProgress = book.progress,
                            onScroll = { fraction, offset ->
                                saveJob?.cancel()
                                saveJob = scope.launch { delay(450); app.library.progress(book, fraction, "txt:$offset:utf16") }
                            },
                            onAsk = onAsk,
                        )
                    }
                }
                error != null -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) { Text(error!!, color = Color(0xFF9B4138), modifier = Modifier.padding(24.dp)) }
                else -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) { Text("Opening book…", color = MaterialTheme.colorScheme.secondary) }
            }
        }
    }
}

@Composable
private fun SingleScrollText(text: String, bookId: String, fontSize: Float, font: String, theme: String, customBackground: String, customForeground: String, initialProgress: Double, onScroll: (Double, Int) -> Unit, onAsk: (String) -> Unit) {
    val context = LocalContext.current
    AndroidView(
        modifier = Modifier.fillMaxSize().padding(horizontal = 18.dp, vertical = 8.dp),
        factory = { ctx ->
            val scroll = ScrollView(ctx).apply { isFillViewport = true; overScrollMode = ScrollView.OVER_SCROLL_NEVER }
            val view = selectableText(ctx, onAsk).apply { setPadding(8.dpInt(ctx), 8.dpInt(ctx), 8.dpInt(ctx), 28.dpInt(ctx)) }
            scroll.addView(view)
            scroll.tag = ReaderViewState(fontSize, font, theme, initialProgress.toFloat())
            scroll.setOnScrollChangeListener { viewScroll, _, scrollY, _, _ ->
                val scrollView = viewScroll as ScrollView
                val total = (scrollView.getChildAt(0)?.height ?: 0) - scrollView.height
                if (total > 0) {
                    val fraction = (scrollY.toFloat() / total).coerceIn(0f, 1f)
                    (scrollView.tag as? ReaderViewState)?.fraction = fraction
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
            val oldFraction = if (state == null) initialProgress.toFloat() else state.fraction
            textView.text = text
            textView.textSize = fontSize
            textView.typeface = typeface(font)
            textView.setTextColor(readerForeground(theme, customForeground))
            textView.setBackgroundColor(readerBackground(theme, customBackground))
            scroll.setBackgroundColor(readerBackground(theme, customBackground))
            scroll.post {
                val total = (scroll.getChildAt(0)?.height ?: 0) - scroll.height
                if (total > 0) scroll.scrollTo(0, (oldFraction.coerceIn(0f, 1f) * total).toInt())
            }
            scroll.tag = ReaderViewState(fontSize, font, theme, oldFraction)
        },
    )
}

@Composable
private fun FacingTextPages(text: String, offset: Int, fontSize: Float, font: String, theme: String, customBackground: String, customForeground: String, onPageChanged: (Int) -> Unit, onAsk: (String) -> Unit) {
    val wide = androidx.compose.ui.platform.LocalConfiguration.current.smallestScreenWidthDp >= 600
    val scope = rememberCoroutineScope()
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
        LaunchedEffect(pageChars, wide) { pager.scrollToPage(spreadForOffset(offset)) }
        LaunchedEffect(pager.currentPage, pageStarts) {
            val first = if (wide) pager.currentPage * 2 else pager.currentPage
            onPageChanged(pageStarts.getOrElse(first) { 0 })
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
                            factory = { ctx -> selectableText(ctx, onAsk) },
                            update = { tv -> tv.text = passage; tv.textSize = fontSize; tv.typeface = typeface(font); tv.setTextColor(readerForeground(theme, customForeground)); tv.setBackgroundColor(readerBackground(theme, customBackground)) },
                        )
                    }
                }
            }
            Row(Modifier.fillMaxWidth().padding(horizontal = 22.dp, vertical = 8.dp), horizontalArrangement = Arrangement.SpaceBetween, verticalAlignment = Alignment.CenterVertically) {
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

private fun selectableText(context: android.content.Context, onAsk: (String) -> Unit): TextView = TextView(context).apply {
    setTextIsSelectable(true)
    textSize = 20f
    setTextColor(Color(0xFF292621).toArgbCompat())
    setLineSpacing(7.dpInt(context).toFloat(), 1.15f)
    setPadding(10.dpInt(context), 10.dpInt(context), 10.dpInt(context), 10.dpInt(context))
    customSelectionActionModeCallback = object : ActionMode.Callback {
        override fun onCreateActionMode(mode: ActionMode, menu: Menu): Boolean {
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
        override fun onDestroyActionMode(mode: ActionMode) = Unit
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
