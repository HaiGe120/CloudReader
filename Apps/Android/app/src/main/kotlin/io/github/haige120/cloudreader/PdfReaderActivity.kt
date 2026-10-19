package io.github.haige120.cloudreader

import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.view.Gravity
import android.view.View
import android.graphics.RectF
import android.util.SparseArray
import android.widget.Button
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.TextView
import androidx.fragment.app.FragmentActivity
import androidx.fragment.app.commit
import androidx.lifecycle.lifecycleScope
import androidx.pdf.PdfDocument
import androidx.pdf.ExperimentalPdfApi
import androidx.pdf.selection.model.TextSelection
import androidx.pdf.selection.Selection
import androidx.pdf.view.PdfView
import androidx.pdf.viewer.fragment.PdfViewerFragment
import io.github.haige120.cloudreader.data.BookRow
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File

class PdfReaderActivity : FragmentActivity() {
    private var selectedText: String = ""
    private lateinit var book: BookRow
    private lateinit var askButton: Button
    private lateinit var pageLabel: TextView

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val root = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL; setBackgroundColor(0xFFF7F3E9.toInt()) }
        val header = LinearLayout(this).apply { gravity = Gravity.CENTER_VERTICAL; setPadding(12, 8, 12, 8) }
        header.addView(Button(this).apply { text = "‹"; contentDescription = "Close reader"; setOnClickListener { finish() } })
        pageLabel = TextView(this).apply { text = "PDF"; textSize = 16f; setTextColor(0xFF292621.toInt()); setPadding(12, 0, 12, 0) }
        header.addView(pageLabel, LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f))
        askButton = Button(this).apply {
            text = "Ask AI about selection"
            visibility = View.GONE
            setOnClickListener {
                if (selectedText.isNotBlank()) {
                    setResult(RESULT_OK, Intent().putExtra(EXTRA_BOOK_ID, intent.getStringExtra(EXTRA_BOOK_ID)).putExtra(EXTRA_SELECTED_TEXT, selectedText.take(18_000)))
                    finish()
                }
            }
        }
        header.addView(askButton)
        root.addView(header)
        root.addView(FrameLayout(this).apply { id = R.id.pdf_viewer_container }, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, 0, 1f))
        setContentView(root)

        val id = intent.getStringExtra(EXTRA_BOOK_ID) ?: run { finish(); return }
        lifecycleScope.launch {
            val resolved = (application as CloudReaderApp).database.libraryDao().book(id)
            if (resolved == null) { finish(); return@launch }
            book = resolved
            pageLabel.text = "${book.title} · ${(book.progress * 100).toInt()}%"
            val file = (application as CloudReaderApp).library.fileFor(book)
            if (file == null) { pageLabel.text = "The local PDF file is missing."; return@launch }
            (application as CloudReaderApp).library.opened(book)
            if (savedInstanceState == null) {
                supportFragmentManager.commit {
                    setReorderingAllowed(true)
                    add(R.id.pdf_viewer_container, CloudPdfFragment.newInstance(Uri.fromFile(file), book.id, book.progress), PDF_TAG)
                }
            }
        }
    }

    internal fun onSelection(text: String?) {
        runOnUiThread {
            selectedText = text.orEmpty().take(18_000)
            askButton.visibility = if (selectedText.isBlank()) View.GONE else View.VISIBLE
        }
    }

    internal fun onPage(page: Int, count: Int) {
        runOnUiThread { if (::pageLabel.isInitialized) pageLabel.text = "${book.title} · Page ${page + 1} of $count" }
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
        fun newInstance(uri: Uri, bookID: String, progress: Double) = CloudPdfFragment().apply {
            arguments = Bundle().apply { putParcelable("documentUri", uri); putString(ARG_BOOK_ID, bookID); putDouble(ARG_PROGRESS, progress) }
            documentUri = uri
        }
    }

    private var pageCount = 0
    private var lastSavedPage = -1

    @OptIn(ExperimentalPdfApi::class)
    override fun onPdfViewCreated(pdfView: PdfView) {
        super.onPdfViewCreated(pdfView)
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
                    if (firstVisiblePage != lastSavedPage) {
                        lastSavedPage = firstVisiblePage
                        (activity?.application as? CloudReaderApp)?.applicationScope?.launch {
                            val app = activity?.application as? CloudReaderApp ?: return@launch
                            val book = app.database.libraryDao().book(bookID) ?: return@launch
                            app.library.progress(book, (firstVisiblePage + 1.0) / count, "pdf:$firstVisiblePage")
                        }
                    }
                }
            }
        })
    }

    override fun onLoadDocumentSuccess(document: PdfDocument) {
        super.onLoadDocumentSuccess(document)
        pageCount = document.pageCount
        val initialPage = (initialProgress * pageCount).let { kotlin.math.ceil(it).toInt() - 1 }.coerceIn(0, (pageCount - 1).coerceAtLeast(0))
        view?.post {
            val pdfView = (view as? android.view.ViewGroup)?.let { findPdfView(it) }
            pdfView?.scrollToPage(initialPage)
        }
        (activity as? PdfReaderActivity)?.extractContext(document, bookID)
    }

    private fun findPdfView(parent: android.view.ViewGroup): PdfView? {
        for (index in 0 until parent.childCount) {
            val child = parent.getChildAt(index)
            if (child is PdfView) return child
            if (child is android.view.ViewGroup) findPdfView(child)?.let { return it }
        }
        return null
    }
}
