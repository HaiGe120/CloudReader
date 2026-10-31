package io.github.haige120.cloudreader

import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.view.MotionEvent
import android.view.ContextThemeWrapper
import android.view.LayoutInflater
import android.graphics.RectF
import android.util.SparseArray
import androidx.core.os.BundleCompat
import androidx.core.view.doOnNextLayout
import androidx.fragment.app.FragmentActivity
import androidx.fragment.app.commit
import androidx.lifecycle.lifecycleScope
import androidx.pdf.PdfDocument
import androidx.pdf.ExperimentalPdfApi
import androidx.pdf.selection.model.TextSelection
import androidx.pdf.selection.Selection
import androidx.pdf.view.PdfView
import androidx.pdf.viewer.fragment.PdfViewerFragment
import io.github.haige120.cloudreader.domain.BookRecord
import io.github.haige120.cloudreader.data.toDomain
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import java.io.File

class PdfReaderActivity : FragmentActivity() {
    private var selectedText: String = ""
    private lateinit var book: BookRecord
    private lateinit var chrome: NativeReaderChrome
    private lateinit var contentTaps: ReaderContentTapObserver
    private var documentView: PdfView? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        chrome = NativeReaderChrome(this, R.id.pdf_viewer_container)
        chrome.setTitle("PDF")
        chrome.setControlsVisible(savedInstanceState?.getBoolean(STATE_CONTROLS_VISIBLE, true) ?: true)
        contentTaps = ReaderContentTapObserver(
            this,
            canStartTap = { event ->
                documentView != null && documentView?.currentSelection == null &&
                    chrome.containsContentPoint(event.rawX, event.rawY)
            },
            canFinishTap = { !isFinishing && !isDestroyed && documentView != null && documentView?.currentSelection == null },
            onTap = { chrome.toggleControls() },
        )
        setContentView(chrome.root)

        val id = intent.getStringExtra(EXTRA_BOOK_ID) ?: run { finish(); return }
        lifecycleScope.launch {
            val resolved = (application as CloudReaderApp).database.libraryDao().book(id)?.toDomain()
            if (resolved == null) { finish(); return@launch }
            book = resolved
            chrome.setTitle(book.title)
            chrome.setProgress("${(book.progress * 100).toInt().coerceIn(0, 100)}%")
            val file = (application as CloudReaderApp).library.fileFor(book)
            if (file == null) { chrome.showError("The local PDF file is missing."); return@launch }
            (application as CloudReaderApp).library.opened(book)
            if (savedInstanceState == null) {
                supportFragmentManager.commit {
                    setReorderingAllowed(true)
                    add(R.id.pdf_viewer_container, CloudPdfFragment.newInstance(Uri.fromFile(file), book.id, book.progress), PDF_TAG)
                }
            }
        }
    }

    override fun dispatchTouchEvent(event: MotionEvent): Boolean {
        if (::contentTaps.isInitialized) contentTaps.observe(event)
        return super.dispatchTouchEvent(event)
    }

    override fun onSaveInstanceState(outState: Bundle) {
        if (::chrome.isInitialized) outState.putBoolean(STATE_CONTROLS_VISIBLE, chrome.controlsVisible)
        super.onSaveInstanceState(outState)
    }

    internal fun onPdfViewCreated(pdfView: PdfView) {
        documentView = pdfView
    }

    internal fun onPdfViewDestroyed() {
        documentView = null
    }

    internal fun onSelection(text: String?) {
        runOnUiThread {
            selectedText = text.orEmpty().take(18_000)
            chrome.setSelectionAction(selectedText.isNotBlank()) {
                if (selectedText.isNotBlank()) {
                    setResult(RESULT_OK, Intent().putExtra(EXTRA_BOOK_ID, intent.getStringExtra(EXTRA_BOOK_ID)).putExtra(EXTRA_SELECTED_TEXT, selectedText))
                    finish()
                }
            }
            // Keep the passage action reachable when a selection starts during immersive reading.
            if (selectedText.isNotBlank()) chrome.setControlsVisible(true)
        }
    }

    internal fun onPage(page: Int, count: Int) {
        runOnUiThread {
            if (::chrome.isInitialized) chrome.setProgress("${page + 1} / $count", "Page ${page + 1} of $count")
        }
    }

    internal fun extractContext(document: PdfDocument, bookID: String) {
        lifecycleScope.launch(Dispatchers.IO) {
            val output = StringBuilder()
            runCatching {
                for (index in 0 until document.pageCount) {
                    val page = document.getPageContent(index)
                    for (line in page?.textContents.orEmpty()) {
                        if (output.length >= PDF_CONTEXT_LIMIT) break
                        if (output.isNotEmpty()) output.append(' ')
                        output.append(line.text)
                        if (output.length > PDF_CONTEXT_LIMIT) output.setLength(PDF_CONTEXT_LIMIT)
                    }
                    output.append('\n')
                    if (output.length >= PDF_CONTEXT_LIMIT) break
                }
            }.onSuccess {
                val target = pdfContextFile(this@PdfReaderActivity, bookID)
                target.parentFile?.mkdirs()
                target.writeText(output.toString())
            }
        }
    }

    companion object {
        const val EXTRA_BOOK_ID = "book_id"
        const val EXTRA_SELECTED_TEXT = "selected_text"
        private const val PDF_TAG = "cloudreader_pdf"
        private const val STATE_CONTROLS_VISIBLE = "reader_controls_visible"
        private const val PDF_CONTEXT_LIMIT = 18_000
        fun pdfContextFile(context: android.content.Context, bookID: String): File = File(File(context.noBackupFilesDir, "pdf-context"), "$bookID.txt")
    }
}

class CloudPdfFragment : PdfViewerFragment() {
    private val bookID get() = requireArguments().getString(ARG_BOOK_ID).orEmpty()
    private val initialProgress get() = requireArguments().getDouble(ARG_PROGRESS, 0.0)

    companion object {
        private const val ARG_BOOK_ID = "book_id"
        private const val ARG_PROGRESS = "progress"
        private const val ARG_DOCUMENT_URI = "documentUri"
        fun newInstance(uri: Uri, bookID: String, progress: Double) = CloudPdfFragment().apply {
            arguments = Bundle().apply { putParcelable(ARG_DOCUMENT_URI, uri); putString(ARG_BOOK_ID, bookID); putDouble(ARG_PROGRESS, progress) }
        }
    }

    private var pageCount = 0
    private var latestPage: Int? = null
    private var readerSession: ReaderSession? = null
    private var activePdfView: PdfView? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // The AndroidX setter starts loading through a fragment ViewModel. It is only safe
        // after attachment; keep the URI in arguments until this lifecycle callback.
        if (documentUri == null) {
            documentUri = BundleCompat.getParcelable(requireArguments(), ARG_DOCUMENT_URI, Uri::class.java)
        }
    }

    override fun onGetLayoutInflater(savedInstanceState: Bundle?): LayoutInflater {
        val inflater = super.onGetLayoutInflater(savedInstanceState)
        // AndroidX PDF's error/search/toolbox views require Material 3 attributes such as
        // colorOnSurface and textAppearanceBodyMedium. Scope them to this native host.
        val themedContext = ContextThemeWrapper(inflater.context, R.style.Theme_CloudReader_PdfViewer)
        return inflater.cloneInContext(themedContext)
    }

    override fun onStop() {
        super.onStop()
        checkpointLatestProgress()
        val session = readerSession ?: return
        (activity?.application as? CloudReaderApp)?.applicationScope?.launch { session.flush() }
    }

    override fun onDestroyView() {
        activePdfView = null
        (activity as? PdfReaderActivity)?.onPdfViewDestroyed()
        super.onDestroyView()
    }

    private fun checkpointLatestProgress() {
        val session = readerSession ?: return
        val page = latestPage ?: return
        val count = pageCount
        if (count <= 0) return
        session.checkpoint((page + 1.0) / count, "pdf:$page")
    }

    private fun createReaderSession(app: CloudReaderApp) {
        readerSession = ReaderSession(bookID, app.applicationScope, ReaderProgressWriter { id, progress, location ->
            val current = app.database.libraryDao().book(id)?.toDomain() ?: return@ReaderProgressWriter
            app.library.progress(current, progress, location)
        })
    }

    @OptIn(ExperimentalPdfApi::class)
    override fun onPdfViewCreated(pdfView: PdfView) {
        super.onPdfViewCreated(pdfView)
        activePdfView = pdfView
        (activity as? PdfReaderActivity)?.onPdfViewCreated(pdfView)
        val app = activity?.application as? CloudReaderApp ?: return
        if (bookID.isNotBlank() && readerSession == null) createReaderSession(app)
        val widthDp = resources.displayMetrics.widthPixels / resources.displayMetrics.density
        pdfView.pagesPerRow = if (widthDp >= 700f) 2 else 1
        pdfView.addOnSelectionChangedListener(object : PdfView.OnSelectionChangedListener {
            override fun onSelectionChanged(newSelection: Selection?) {
                (activity as? PdfReaderActivity)?.onSelection((newSelection as? TextSelection)?.text?.toString())
            }
        })
        pdfView.addOnViewportChangedListener(object : PdfView.OnViewportChangedListener {
            override fun onViewportChanged(firstVisiblePage: Int, visiblePagesCount: Int, pageLocations: SparseArray<RectF>, zoomLevel: Float) {
                val count = pageCount
                if (count > 0) {
                    (activity as? PdfReaderActivity)?.onPage(firstVisiblePage, count)
                    latestPage = firstVisiblePage.coerceIn(0, count - 1)
                    checkpointLatestProgress()
                }
            }
        })
    }

    override fun onLoadDocumentSuccess(document: PdfDocument) {
        super.onLoadDocumentSuccess(document)
        pageCount = document.pageCount
        val initialPage = (initialProgress * pageCount).let { kotlin.math.ceil(it).toInt() - 1 }.coerceIn(0, (pageCount - 1).coerceAtLeast(0))
        // Use the view supplied by the public callback; the fragment's getter is restricted.
        activePdfView?.let { viewer ->
            // AndroidX calls this before assigning the document and making PdfView visible.
            // A queued message can precede layout and request zero-size bitmaps.
            viewer.doOnNextLayout {
                if (activePdfView === viewer && viewer.width > 0 && viewer.height > 0 && viewer.pdfDocument === document) {
                    viewer.scrollToPage(initialPage)
                }
            }
        }
        (activity as? PdfReaderActivity)?.extractContext(document, bookID)
    }
}
