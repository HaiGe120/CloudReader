package io.github.haige120.cloudreader

import android.os.Bundle
import android.content.res.Configuration
import androidx.appcompat.app.AppCompatActivity
import androidx.lifecycle.lifecycleScope
import io.github.haige120.cloudreader.domain.BookRecord
import io.github.haige120.cloudreader.data.toDomain
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.readium.r2.navigator.epub.EpubNavigatorFragment
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
    private var readerHost: EpubReaderHost? = null
    private var readerSession: ReaderSession? = null
    private var restoredLocator: String? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        // Reopen the publication before creating a fresh navigator. A restored fragment
        // cannot safely retain an in-memory publication after process death.
        restoredLocator = savedInstanceState?.getString("reader.locator")
        super.onCreate(null)
        val bookId = intent.getStringExtra(EXTRA_BOOK_ID)
        val containerId = R.id.epub_viewer_container
        chrome = NativeReaderChrome(this, containerId, showRestoreControl = false, immersiveSystemBars = true)
        chrome.setTitle("EPUB")
        setContentView(chrome.root)

        if (bookId == null) { chrome.showError("Book not found."); return }
        lifecycleScope.launch {
            runCatching {
                val result = app.database.libraryDao().book(bookId)?.toDomain() ?: error("Book not found.")
                book = result
                readerSession = ReaderSession(result.id, app.applicationScope, ReaderProgressWriter { id, progress, location ->
                    val current = app.database.libraryDao().book(id)?.toDomain() ?: return@ReaderProgressWriter
                    app.library.progress(current, progress, location)
                })
                chrome.setTitle(result.title)
                chrome.setProgress("${(result.progress * 100).toInt().coerceIn(0, 100)}%")
                app.library.opened(result)
                openPublication(result, containerId)
            }.onFailure {
                if (it is CancellationException) throw it
                chrome.showError(it.localizedMessage ?: "This EPUB could not be opened.")
            }
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
        val savedLocator = restoredLocator?.let { raw -> runCatching { Locator.fromJSON(org.json.JSONObject(raw)) }.getOrNull() }
            ?: book.localLocation?.takeIf { it.startsWith("readium:") }
            ?.removePrefix("readium:")
            ?.let { raw -> runCatching { Locator.fromJSON(org.json.JSONObject(raw)) }.getOrNull() }
        val settings = EpubReaderAppearance.SETTING_KEYS.mapNotNull { key ->
            app.preferences.get(key)?.let { key to it }
        }.toMap()
        withContext(Dispatchers.Main) {
            readerHost = EpubReaderHost(
                this@EpubReaderActivity, chrome, containerId,
                onSettingChanged = { key, value -> app.preferences.set(key, value) },
                onLocatorChanged = { locator -> checkpoint(locator) },
                onSelectedText = { selected ->
                    setResult(RESULT_OK, android.content.Intent()
                        .putExtra(PdfReaderActivity.EXTRA_BOOK_ID, book.id)
                        .putExtra(PdfReaderActivity.EXTRA_SELECTED_TEXT, selected.take(18_000)))
                    finish()
                },
            ).also { it.attach(publication, savedLocator, EpubReaderAppearance.fromSettings(settings)) }
        }
    }

    private fun checkpoint(locator: Locator) {
        val fraction = locator.locations.totalProgression ?: locator.locations.progression ?: book?.progress ?: 0.0
        chrome.setProgress((fraction * 100).toInt().coerceIn(0, 100).toString() + "%")
        readerSession?.checkpoint(fraction, "readium:" + locator.toJSON())
    }

    override fun onConfigurationChanged(newConfig: Configuration) {
        super.onConfigurationChanged(newConfig)
        readerHost?.let { it.applyAppearance(it.appearance) }
    }

    override fun onStop() {
        readerHost?.navigator?.currentLocator?.value?.let(::checkpoint)
        readerSession?.let { session -> app.applicationScope.launch { session.flush() } }
        super.onStop()
    }

    override fun onSaveInstanceState(outState: Bundle) {
        readerHost?.navigator?.currentLocator?.value?.let { outState.putString("reader.locator", it.toJSON().toString()) }
        super.onSaveInstanceState(outState)
    }

    override fun onDestroy() {
        readerHost?.close()
        readerHost = null
        super.onDestroy()
    }
}
