package io.github.haige120.cloudreader

import android.os.Bundle
import android.view.Gravity
import android.view.ViewGroup
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.TextView
import androidx.appcompat.app.AppCompatActivity
import androidx.core.view.setPadding
import androidx.lifecycle.lifecycleScope
import androidx.fragment.app.commitNow
import io.github.haige120.cloudreader.data.BookRow
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.readium.r2.navigator.epub.EpubNavigatorFactory
import org.readium.r2.navigator.epub.EpubNavigatorFragment
import org.readium.r2.shared.publication.Locator
import org.readium.r2.shared.util.http.DefaultHttpClient
import org.readium.r2.shared.util.asset.AssetRetriever
import org.readium.r2.streamer.PublicationOpener
import org.readium.r2.streamer.parser.DefaultPublicationParser
import java.io.File

class EpubReaderActivity : AppCompatActivity() {
    companion object { const val EXTRA_BOOK_ID = "book_id" }

    private val app get() = application as CloudReaderApp
    private lateinit var status: TextView
    private lateinit var titleView: TextView
    private var book: BookRow? = null

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
        val root = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        val toolbar = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(12)
        }
        val close = TextView(this).apply {
            text = "‹  Library"
            textSize = 16f
            contentDescription = "Close book"
            setOnClickListener { finish() }
        }
        titleView = TextView(this).apply {
            textSize = 18f
            setPadding(20, 0, 0, 0)
        }
        status = TextView(this).apply {
            textSize = 13f
            gravity = Gravity.END
            setPadding(12, 0, 0, 0)
        }
        toolbar.addView(close, LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT))
        toolbar.addView(titleView, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
        toolbar.addView(status, LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT))
        root.addView(toolbar)
        val containerId = R.id.epub_viewer_container
        root.addView(FrameLayout(this).apply { setId(containerId) }, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f))
        setContentView(root)

        if (bookId == null) { status.text = "Book not found"; return }
        lifecycleScope.launch {
            runCatching {
                val result = app.database.libraryDao().book(bookId) ?: error("Book not found.")
                book = result
                titleView.text = result.title
                app.library.opened(result)
                openPublication(result, containerId)
            }.onFailure { status.text = it.localizedMessage ?: "This EPUB could not be opened." }
        }
    }

    private suspend fun openPublication(book: BookRow, containerId: Int) = withContext(Dispatchers.IO) {
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
            lifecycleScope.launch {
                navigator.currentLocator.collect { locator ->
                    val fraction = locator.locations.totalProgression ?: locator.locations.progression ?: book.progress
                    status.text = "${(fraction * 100).toInt().coerceIn(0, 100)}%"
                    app.library.progress(book, fraction, "readium:${locator.toJSON()}")
                }
            }
        }
    }
}
