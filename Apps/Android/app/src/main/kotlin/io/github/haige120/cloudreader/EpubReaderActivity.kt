package io.github.haige120.cloudreader

import android.os.Bundle
import androidx.appcompat.app.AppCompatActivity
import androidx.lifecycle.lifecycleScope
import androidx.fragment.app.commitNow
import io.github.haige120.cloudreader.domain.BookRecord
import io.github.haige120.cloudreader.data.toDomain
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.readium.r2.navigator.epub.EpubNavigatorFactory
import org.readium.r2.navigator.epub.EpubNavigatorFragment
import org.readium.r2.navigator.input.InputListener
import org.readium.r2.navigator.input.TapEvent
import org.readium.r2.navigator.util.DirectionalNavigationAdapter
import org.readium.r2.shared.ExperimentalReadiumApi
import org.readium.r2.shared.publication.Locator
import org.readium.r2.shared.util.http.DefaultHttpClient
import org.readium.r2.shared.util.asset.AssetRetriever
import org.readium.r2.streamer.PublicationOpener
import org.readium.r2.streamer.parser.DefaultPublicationParser

class EpubReaderActivity : AppCompatActivity() {
    companion object { const val EXTRA_BOOK_ID = "book_id" }

    private val app get() = application as CloudReaderApp
    private lateinit var chrome: NativeReaderChrome
    private var book: BookRecord? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        // Readium restores child fragments through a factory. If Android recreated this
        // Activity after process death, the Publication is no longer in memory; finish
        // cleanly and reopen from the persisted Locator instead of restoring a dead view.
        if (savedInstanceState != null) {
            supportFragmentManager.fragmentFactory = EpubNavigatorFragment.createDummyFactory()
            super.onCreate(savedInstanceState)
            finish()
            return
        }
        super.onCreate(savedInstanceState)
        val bookId = intent.getStringExtra(EXTRA_BOOK_ID)
        val containerId = R.id.epub_viewer_container
        chrome = NativeReaderChrome(this, containerId)
        chrome.setTitle("EPUB")
        setContentView(chrome.root)

        if (bookId == null) { chrome.showError("Book not found."); return }
        lifecycleScope.launch {
            runCatching {
                val result = app.database.libraryDao().book(bookId)?.toDomain() ?: error("Book not found.")
                book = result
                chrome.setTitle(result.title)
                chrome.setProgress("${(result.progress * 100).toInt().coerceIn(0, 100)}%")
                app.library.opened(result)
                openPublication(result, containerId)
            }.onFailure { chrome.showError(it.localizedMessage ?: "This EPUB could not be opened.") }
        }
    }

    @OptIn(ExperimentalReadiumApi::class)
    private suspend fun openPublication(book: BookRecord, containerId: Int) = withContext(Dispatchers.IO) {
        val file = app.library.fileFor(book) ?: error("The local book file is missing.")
        val httpClient = DefaultHttpClient()
        val assetRetriever = AssetRetriever(contentResolver, httpClient)
        val opener = PublicationOpener(
            DefaultPublicationParser(this@EpubReaderActivity, httpClient, assetRetriever, null)
        )
        val assetResult = assetRetriever.retrieve(file)
        val asset = assetResult.getOrNull() ?: error("Could not open this EPUB: ${assetResult.failureOrNull()}")
        val publicationResult = opener.open(asset, allowUserInteraction = false)
        val publication = publicationResult.getOrNull() ?: error("Could not read this EPUB: ${publicationResult.failureOrNull()}")
        val savedLocator = book.localLocation?.takeIf { it.startsWith("readium:") }
            ?.removePrefix("readium:")
            ?.let { raw -> runCatching { Locator.fromJSON(org.json.JSONObject(raw)) }.getOrNull() }
        val factory = EpubNavigatorFactory(publication).createFragmentFactory(initialLocator = savedLocator)
        withContext(Dispatchers.Main) {
            supportFragmentManager.fragmentFactory = factory
            supportFragmentManager.commitNow {
                replace(containerId, EpubNavigatorFragment::class.java, Bundle(), "epub-navigator")
            }
            val navigator = supportFragmentManager.findFragmentByTag("epub-navigator") as EpubNavigatorFragment
            // Readium emits these taps after internal links/selection handling. Keep its edge
            // taps and keyboard navigation separate from the center tap used by reader chrome.
            navigator.addInputListener(object : InputListener {
                override fun onTap(event: TapEvent): Boolean {
                    if (!isReaderChromeCenterTap(event.point.x, navigator.publicationView.width)) return false
                    chrome.toggleControls()
                    return true
                }
            })
            navigator.addInputListener(DirectionalNavigationAdapter(navigator))
            lifecycleScope.launch {
                navigator.currentLocator.collect { locator ->
                    val fraction = locator.locations.totalProgression ?: locator.locations.progression ?: book.progress
                    chrome.setProgress("${(fraction * 100).toInt().coerceIn(0, 100)}%")
                    app.library.progress(book, fraction, "readium:${locator.toJSON()}")
                }
            }
        }
    }
}
