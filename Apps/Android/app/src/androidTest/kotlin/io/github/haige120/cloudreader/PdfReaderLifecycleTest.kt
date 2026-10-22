package io.github.haige120.cloudreader

import android.content.Context
import android.content.Intent
import android.graphics.Paint
import android.graphics.pdf.PdfDocument
import android.net.Uri
import android.os.Bundle
import android.os.SystemClock
import android.view.View
import android.view.ViewGroup
import androidx.pdf.view.PdfView
import androidx.test.core.app.ActivityScenario
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import java.util.UUID
import java.util.concurrent.atomic.AtomicBoolean

/** Real PDF rendering, with temporary bytes and no book ID or library progress session. */
@RunWith(AndroidJUnit4::class)
class PdfReaderLifecycleTest {
    @Test fun temporaryPdfLoadsAfterAttachmentAndFragmentStateRestoration() {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val folder = File(context.cacheDir, "pdf-lifecycle-${UUID.randomUUID()}").apply { check(mkdirs()) }
        val file = File(folder, "fixture.pdf")
        createPdf(file)
        val uri = Uri.fromFile(file)
        try {
            // This existing host shows an error shell without accessing a book/library record.
            val intent = Intent(context, EpubReaderActivity::class.java)
            ActivityScenario.launch<EpubReaderActivity>(intent).use { scenario ->
                val contentLoaded = AtomicBoolean(false)
                scenario.onActivity { activity ->
                    // Construction itself must be safe before the Fragment is attached.
                    val fragment = CloudPdfFragment.newInstance(uri, bookID = "", progress = 0.0)
                    assertTrue(!fragment.isAdded)
                    activity.findViewById<ViewGroup>(R.id.epub_viewer_container).removeAllViews()
                    activity.supportFragmentManager.beginTransaction()
                        .replace(R.id.epub_viewer_container, fragment, PDF_TAG)
                        .commitNow()
                    watchFirstContentLoad(fragment, contentLoaded)
                }
                awaitRendered(scenario, uri, contentLoaded)
                scenario.onActivity { activity ->
                    val manager = activity.supportFragmentManager
                    val original = requireNotNull(manager.findFragmentByTag(PDF_TAG))
                    val arguments = Bundle(requireNotNull(original.arguments))
                    val saved = manager.saveFragmentInstanceState(original)
                    manager.beginTransaction().remove(original).commitNow()
                    val restored = manager.fragmentFactory.instantiate(activity.classLoader, CloudPdfFragment::class.java.name).apply {
                        this.arguments = arguments
                        setInitialSavedState(saved)
                    }
                    contentLoaded.set(false)
                    manager.beginTransaction().replace(R.id.epub_viewer_container, restored, PDF_TAG).commitNow()
                    watchFirstContentLoad(restored as CloudPdfFragment, contentLoaded)
                }
                awaitRendered(scenario, uri, contentLoaded)
            }
        } finally {
            folder.deleteRecursively()
        }
    }

    private fun watchFirstContentLoad(fragment: CloudPdfFragment, contentLoaded: AtomicBoolean) {
        val viewer = requireNotNull(fragment.view?.let(::findPdfView))
        // Register before returning from the attachment callback, ahead of the first draw.
        viewer.addOnFirstContentLoadListener { contentLoaded.set(true) }
    }

    private fun awaitRendered(scenario: ActivityScenario<EpubReaderActivity>, uri: Uri, contentLoaded: AtomicBoolean) {
        val deadline = SystemClock.uptimeMillis() + 20_000
        var rendered = false
        while (!rendered && SystemClock.uptimeMillis() < deadline) {
            scenario.onActivity { activity ->
                val fragment = activity.supportFragmentManager.findFragmentByTag(PDF_TAG) as? CloudPdfFragment
                val viewer = fragment?.view?.let(::findPdfView)
                if (viewer?.pdfDocument != null && contentLoaded.get()) {
                    assertEquals(uri, fragment?.documentUri)
                    assertEquals(3, viewer.pdfDocument?.pageCount)
                    assertTrue("The PDF must have a visible page", viewer.visiblePagesCount > 0)
                    rendered = true
                }
            }
            if (!rendered) SystemClock.sleep(50)
        }
        assertTrue("The temporary PDF must actually render through the fragment lifecycle", rendered)
    }

    private fun createPdf(file: File) {
        val document = PdfDocument()
        try {
            val paint = Paint().apply { textSize = 20f }
            for (index in 0..2) {
                val page = document.startPage(PdfDocument.PageInfo.Builder(420, 595, index).create())
                page.canvas.drawText("CloudReader isolated PDF page ${index + 1}", 20f, 80f, paint)
                document.finishPage(page)
            }
            file.outputStream().use(document::writeTo)
        } finally {
            document.close()
        }
        assertTrue(file.length() > 0)
    }

    private fun findPdfView(view: View): PdfView? {
        if (view is PdfView) return view
        if (view is ViewGroup) for (index in 0 until view.childCount) findPdfView(view.getChildAt(index))?.let { return it }
        return null
    }

    companion object { private const val PDF_TAG = "isolated-pdf-lifecycle" }
}
