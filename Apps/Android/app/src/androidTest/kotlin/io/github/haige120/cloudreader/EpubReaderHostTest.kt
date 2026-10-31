package io.github.haige120.cloudreader

import android.content.Intent
import android.graphics.Rect
import android.os.SystemClock
import android.view.View
import android.view.ViewGroup
import android.webkit.WebView
import androidx.test.core.app.ActivityScenario
import androidx.test.core.app.ApplicationProvider
import androidx.test.espresso.Espresso.onView
import androidx.test.espresso.action.CoordinatesProvider
import androidx.test.espresso.action.GeneralClickAction
import androidx.test.espresso.action.Press
import androidx.test.espresso.action.Tap
import androidx.test.espresso.action.ViewActions.click
import androidx.test.espresso.action.ViewActions.scrollTo
import androidx.test.espresso.assertion.ViewAssertions.doesNotExist
import androidx.test.espresso.assertion.ViewAssertions.matches
import androidx.test.espresso.matcher.ViewMatchers.isDisplayed
import androidx.test.espresso.matcher.ViewMatchers.withContentDescription
import androidx.test.espresso.matcher.ViewMatchers.withId
import androidx.test.espresso.matcher.ViewMatchers.withText
import androidx.test.ext.junit.runners.AndroidJUnit4
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import org.hamcrest.Matchers.not
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.readium.r2.navigator.epub.EpubNavigatorFragment
import org.readium.r2.navigator.preferences.ColumnCount
import org.readium.r2.navigator.preferences.FontFamily
import org.readium.r2.shared.ExperimentalReadiumApi
import org.readium.r2.shared.publication.Locator
import org.readium.r2.shared.publication.Publication
import org.readium.r2.shared.util.asset.AssetRetriever
import org.readium.r2.shared.util.http.DefaultHttpClient
import org.readium.r2.streamer.PublicationOpener
import org.readium.r2.streamer.parser.DefaultPublicationParser
import java.io.File
import java.util.Collections
import java.util.zip.CRC32
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream

/** Real Readium/WebView fixtures; never opens the application database, preferences or library. */
@OptIn(ExperimentalReadiumApi::class)
@RunWith(AndroidJUnit4::class)
class EpubReaderHostTest {
    @Test fun centerTapRestoresFullyHiddenControlsAndEdgeTapsStillTurnPages() = withReader { reader ->
        onView(withText("Show controls")).check(doesNotExist())
        onView(withContentDescription("Show reading controls")).check(doesNotExist())
        onView(withContentDescription("Back to library")).check(matches(not(isDisplayed())))
        reader.assertHidden()

        reader.tapPublication(0.5f)
        reader.await("A center tap must show the toolbar") { reader.controlsVisible() }
        onView(withContentDescription("Reading appearance")).check(matches(isDisplayed()))
        onView(withContentDescription("Back to library")).check(matches(isDisplayed()))
        reader.tapPublication(0.5f)
        reader.await("A second center tap must hide the toolbar") { !reader.controlsVisible() }
        reader.assertHidden()

        val before = reader.locator().locations.progression ?: 0.0
        reader.tapPublication(0.90f)
        reader.await("An edge tap must advance Readium while the toolbar stays hidden") {
            (reader.locator().locations.progression ?: 0.0) > before + 0.001
        }
        reader.assertHidden()
        val advanced = reader.locator()
        reader.tapPublication(0.5f)
        reader.await("Controls must remain recoverable after a page turn") { reader.controlsVisible() }
        reader.await("Showing the toolbar must retain the reading passage") {
            samePassage(advanced, reader.locator())
        }
        assertTrue("The real publication, rather than an empty shell, must remain visible", reader.css().getInt("paragraphs") >= 80)
    }

    @Test fun appearancePanelChangesRealPublicationTypographyColorsAndAllPageModes() = withReader { reader ->
        reader.tapPublication(0.5f)
        reader.await("Center tap must expose appearance") { reader.controlsVisible() }
        onView(withContentDescription("Reading appearance")).perform(click())
        onView(withText("Page layout")).check(matches(isDisplayed()))
        onView(withText("Dark")).perform(scrollTo(), click())
        onView(withText("Mono")).perform(scrollTo(), click())
        onView(withContentDescription("Larger text")).perform(scrollTo(), click())
        onView(withText("Done")).perform(click())

        reader.await("All appearance changes must be saved through the supplied store boundary") {
            reader.changes["reader.theme"] == "dark" && reader.changes["reader.font"] == "mono" &&
                reader.changes["reader.fontSize"] == "21"
        }
        reader.await("The publication must use the selected theme and font") {
            val css = reader.css()
            css.optString("background") == "rgb(35, 35, 34)" &&
                css.optString("foreground") == "rgb(229, 225, 216)" &&
                css.optString("font").contains("monospace", ignoreCase = true)
        }
        reader.onMain {
            assertEquals(FontFamily.MONOSPACE, reader.navigator().settings.value.fontFamily)
            assertEquals(21.0 / 16.0, reader.navigator().settings.value.fontSize, 0.0001)
        }
        var nativeTextZoom = 100
        reader.onMain { nativeTextZoom = reader.visibleWebView().settings.textZoom }
        // Readium supports CSS font sizing and native WebView zoom. Check their actual
        // combined effect rather than assuming which supported configuration is active.
        assertEquals("Text size must reach the actual WebView", 21.0, reader.css().getDouble("fontSize") * nativeTextZoom / 100.0, 0.15)

        reader.changeLayout("Scrolling", "scroll")
        reader.await("Scrolling must change the real document's overflow mode") {
            val css = reader.css()
            css.optString("view") == "readium-scroll-on" && css.optDouble("scrollHeight") > css.optDouble("height")
        }
        reader.onMain { assertTrue(reader.navigator().settings.value.scroll) }

        // Advance the actual scrolling document before reflowing it to pages.
        reader.javascript("window.scrollBy(0, window.innerHeight * 3); true")
        reader.await("Native scrolling must publish a nonzero locator") { (reader.locator().locations.progression ?: 0.0) > 0.001 }
        val scrollingPassage = reader.locator()
        reader.changeLayout("One page", "single")
        reader.await("One page must restore paginated overflow and one column") {
            val css = reader.css()
            css.optString("view") == "readium-paged-on" && css.optString("requestedColumns") == "1"
        }
        reader.onMain {
            assertFalse(reader.navigator().settings.value.scroll)
            assertEquals(ColumnCount.ONE, reader.navigator().settings.value.columnCount)
        }
        reader.await("Changing from scrolling to pages must retain the source passage") { samePassage(scrollingPassage, reader.locator()) }

        val singlePassage = reader.locator()
        reader.changeLayout("Two pages", "facing")
        var expectedColumns = "1"
        reader.onMain {
            val widthDp = reader.navigator().publicationView.width / reader.activity.resources.displayMetrics.density
            expectedColumns = if (widthDp >= 600f) "2" else "1"
        }
        reader.await("Two pages must apply Readium's column policy") {
            val css = reader.css()
            css.optString("view") == "readium-paged-on" && css.optString("requestedColumns") == expectedColumns &&
                css.optString("actualColumns") == expectedColumns
        }
        reader.onMain {
            val widthDp = reader.navigator().publicationView.width / reader.activity.resources.displayMetrics.density
            val expected = if (widthDp >= 600f) ColumnCount.TWO else ColumnCount.ONE
            assertEquals("Two pages must adapt to the actual viewport width", expected, reader.navigator().settings.value.columnCount)
        }
        reader.await("Changing columns must retain the source passage") { samePassage(singlePassage, reader.locator()) }
        reader.assertNoRestoreOverlay()
    }

    private fun samePassage(before: Locator, after: Locator): Boolean =
        before.href == after.href && kotlin.math.abs((before.locations.progression ?: 0.0) - (after.locations.progression ?: 0.0)) < 0.08

    private fun withReader(block: (FixtureReader) -> Unit) {
        val context = ApplicationProvider.getApplicationContext<android.content.Context>()
        val directory = File(context.cacheDir, "epub-host-ui-${java.util.UUID.randomUUID()}").apply { mkdirs() }
        val file = createPublication(directory)
        val publication = runBlocking(Dispatchers.IO) {
            val http = DefaultHttpClient()
            val retriever = AssetRetriever(context.contentResolver, http)
            val asset = retriever.retrieve(file).getOrNull() ?: error("Fixture EPUB could not be retrieved")
            PublicationOpener(DefaultPublicationParser(context, http, retriever, null))
                .open(asset, allowUserInteraction = false).getOrNull() ?: error("Fixture EPUB could not be parsed")
        }
        val intent = Intent(context, EpubReaderActivity::class.java)
        try {
            ActivityScenario.launch<EpubReaderActivity>(intent).use { scenario ->
                lateinit var reader: FixtureReader
                scenario.onActivity { activity ->
                    val chrome = NativeReaderChrome(activity, R.id.epub_viewer_container, showRestoreControl = false, immersiveSystemBars = true)
                    chrome.setTitle("Isolated EPUB fixture")
                    activity.setContentView(chrome.root)
                    reader = FixtureReader(activity, scenario, chrome)
                    reader.host = EpubReaderHost(
                        activity, chrome, R.id.epub_viewer_container,
                        onSettingChanged = { key, value -> reader.changes[key] = value },
                        onLocatorChanged = {},
                    )
                    reader.host.attach(publication, initialLocator = null, appearance = EpubReaderAppearance(theme = "light"))
                }
                try {
                    reader.await("The real EPUB document must finish loading", 20_000) { reader.css().optInt("paragraphs") >= 80 }
                    block(reader)
                } finally {
                    scenario.onActivity { reader.host.close() }
                }
            }
        } finally {
            publication.close()
            directory.deleteRecursively()
        }
    }

    private class FixtureReader(
        val activity: EpubReaderActivity,
        private val scenario: ActivityScenario<EpubReaderActivity>,
        private val chrome: NativeReaderChrome,
    ) {
        lateinit var host: EpubReaderHost
        val changes: MutableMap<String, String> = Collections.synchronizedMap(mutableMapOf())

        fun onMain(action: () -> Unit) { scenario.onActivity { action() } }
        fun navigator(): EpubNavigatorFragment = requireNotNull(host.navigator)
        fun controlsVisible(): Boolean { var result = false; onMain { result = chrome.controlsVisible }; return result }
        fun locator(): Locator { lateinit var locator: Locator; onMain { locator = navigator().currentLocator.value }; return locator }

        fun tapPublication(horizontalFraction: Float) {
            val coordinates = CoordinatesProvider { view ->
                val bounds = Rect()
                check(view.getGlobalVisibleRect(bounds)) { "EPUB publication is not visible" }
                floatArrayOf(bounds.left + bounds.width() * horizontalFraction, bounds.exactCenterY())
            }
            onView(withId(R.id.epub_viewer_container)).perform(GeneralClickAction(Tap.SINGLE, coordinates, Press.FINGER))
        }

        fun changeLayout(label: String, value: String) {
            onView(withContentDescription("Reading appearance")).perform(click())
            onView(withText(label)).perform(scrollTo(), click())
            onView(withText("Done")).perform(click())
            await("The selected layout must be saved") { changes[EpubReaderAppearance.LAYOUT_KEY] == value }
        }

        fun assertHidden() {
            assertFalse("No toolbar should cover the publication", controlsVisible())
            onView(withContentDescription("Reading appearance")).check(matches(not(isDisplayed())))
            assertNoRestoreOverlay()
        }

        fun assertNoRestoreOverlay() {
            onView(withText("Show controls")).check(doesNotExist())
            onView(withContentDescription("Show reading controls")).check(doesNotExist())
        }

        fun javascript(script: String): String? = runBlocking {
            withTimeout(5_000) { withContext(Dispatchers.Main) { host.navigator?.evaluateJavascript(script) } }
        }

        fun css(): JSONObject {
            val raw = javascript("""
                (() => {
                  const html = document.documentElement;
                  const p = document.querySelector('p');
                  if (!p) return null;
                  const root = getComputedStyle(html), prose = getComputedStyle(p);
                  return { paragraphs: document.querySelectorAll('p').length, fontSize: parseFloat(prose.fontSize),
                    background: root.backgroundColor, foreground: prose.color, font: prose.fontFamily,
                    view: root.getPropertyValue('--USER__view').trim(),
                    requestedColumns: root.getPropertyValue('--USER__colCount').trim(),
                    actualColumns: root.columnCount, height: innerHeight,
                    scrollHeight: html.scrollHeight };
                })()
            """.trimIndent())
            return if (raw == null || raw == "null") JSONObject() else JSONObject(raw)
        }

        fun visibleWebView(): WebView {
            fun find(view: View): WebView? {
                if (view is WebView && view.isShown) return view
                if (view is ViewGroup) for (index in 0 until view.childCount) find(view.getChildAt(index))?.let { return it }
                return null
            }
            return requireNotNull(find(navigator().publicationView)) { "Readium must contain a visible WebView" }
        }

        fun await(message: String, timeout: Long = 10_000, predicate: () -> Boolean) {
            val deadline = SystemClock.uptimeMillis() + timeout
            var error: Throwable? = null
            while (SystemClock.uptimeMillis() < deadline) {
                try { if (predicate()) return } catch (failure: Exception) { error = failure }
                SystemClock.sleep(100)
            }
            throw AssertionError(message, error)
        }
    }

    private fun createPublication(directory: File): File {
        val file = File(directory, "reader-controls.epub")
        ZipOutputStream(file.outputStream()).use { zip ->
            fun entry(name: String, contents: String, stored: Boolean = false) {
                val bytes = contents.toByteArray(Charsets.UTF_8)
                zip.putNextEntry(ZipEntry(name).apply {
                    if (stored) { method = ZipEntry.STORED; size = bytes.size.toLong(); crc = CRC32().apply { update(bytes) }.value }
                })
                zip.write(bytes)
                zip.closeEntry()
            }
            entry("mimetype", "application/epub+zip", stored = true)
            entry("META-INF/container.xml", """<?xml version="1.0"?><container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="EPUB/package.opf" media-type="application/oebps-package+xml"/></rootfiles></container>""")
            entry("EPUB/package.opf", """<?xml version="1.0"?><package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="fixture-id"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="fixture-id">urn:uuid:7a22a540-71f2-4637-b96a-3a9103cf48dc</dc:identifier><dc:title>Isolated EPUB fixture</dc:title><dc:language>en</dc:language><meta property="dcterms:modified">2026-10-24T00:00:00Z</meta></metadata><manifest><item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/><item id="chapter" href="chapter.xhtml" media-type="application/xhtml+xml"/></manifest><spine><itemref idref="chapter"/></spine></package>""")
            entry("EPUB/nav.xhtml", """<?xml version="1.0"?><html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><head><title>Contents</title></head><body><nav epub:type="toc"><ol><li><a href="chapter.xhtml">Reading fixture</a></li></ol></nav></body></html>""")
            val paragraphs = (1..120).joinToString("\n") { index ->
                """<p id="passage-$index">Passage $index. A quiet page should leave room for reading. This original fixture provides enough words for native pagination, a long scrolling document, color and typography checks, and a stable position while changing the reading layout.</p>"""
            }
            entry("EPUB/chapter.xhtml", """<?xml version="1.0"?><html xmlns="http://www.w3.org/1999/xhtml"><head><title>Reading fixture</title><style>p { font-family: cursive; font-size: 37px; color: #aa1111; } em { font-style: italic; }</style></head><body><h1>A quiet page</h1>$paragraphs</body></html>""")
        }
        return file
    }
}
