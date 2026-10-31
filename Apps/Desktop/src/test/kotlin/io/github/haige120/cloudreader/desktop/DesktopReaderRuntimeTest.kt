package io.github.haige120.cloudreader.desktop

import io.github.haige120.cloudreader.core.reader.*
import io.github.haige120.cloudreader.core.application.*
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test
import java.nio.file.Files
import java.time.Instant
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference
import javax.swing.JFrame
import javax.swing.SwingUtilities

/** Opt-in target-OS GUI gate: actually loads WebKit, turns and restores a page. */
class DesktopReaderRuntimeTest {
    @Test fun nativePdfSpreadRetainsOddLastPageAndPortableProgress(){
        assumeTrue("Enable on a graphical target OS or Xvfb",System.getenv("CLOUDREADER_GUI_TESTS")=="1")
        val root=Files.createTempDirectory("desktop-pdf-spread");val file=root.resolve("spread.pdf")
        org.apache.pdfbox.pdmodel.PDDocument().use{doc->repeat(3){doc.addPage(org.apache.pdfbox.pdmodel.PDPage())};doc.save(file.toFile())}
        var host:PdfDesktopHost?=null;var frame:JFrame?=null
        val status=AtomicReference("");val fraction=AtomicReference(0.0)
        try{
            SwingUtilities.invokeAndWait{
                val reader=PdfDesktopHost(BookRecord(newBookId(),"Spread",BookFormat.PDF,file,Instant.now(),progress=2.0/3),{status.set(it)},{p,_->fraction.set(p)})
                host=reader;frame=JFrame("CloudReader isolated PDF spread check").apply{add(reader.component);setSize(1200,800);isVisible=true}
                reader.appearance(ReadingAppearance(layout=ReaderLayout.SPREAD))
            }
            await("Two native PDF pages must render together"){status.get()=="Pages 1–2 of 3"}
            assertEquals(2.0/3,fraction.get(),.0001)
            SwingUtilities.invokeAndWait{host!!.next()}
            await("The odd last PDF page must remain reachable"){status.get()=="Page 3 of 3"}
            assertEquals(1.0,fraction.get(),.0001)
        }finally{SwingUtilities.invokeAndWait{host?.close();frame?.dispose()};root.toFile().deleteRecursively()}
    }
    @Test fun nativePdfTextSelectionProvidesOnlyTheSelectedPassage() {
        assumeTrue("Enable on a graphical target OS or Xvfb",System.getenv("CLOUDREADER_GUI_TESTS")=="1")
        val root=Files.createTempDirectory("desktop-pdf-selection")
        val file=root.resolve("selection.pdf")
        org.apache.pdfbox.pdmodel.PDDocument().use { doc ->
            val page=org.apache.pdfbox.pdmodel.PDPage();doc.addPage(page)
            org.apache.pdfbox.pdmodel.PDPageContentStream(doc,page).use { stream ->
                stream.beginText();stream.setFont(org.apache.pdfbox.pdmodel.font.PDType1Font(org.apache.pdfbox.pdmodel.font.Standard14Fonts.FontName.HELVETICA),16f)
                stream.newLineAtOffset(72f,720f);stream.showText("Selected passage");stream.endText()
            }
            doc.save(file.toFile())
        }
        val ready=CountDownLatch(1)
        var host:PdfDesktopHost?=null;var frame:JFrame?=null
        try {
            SwingUtilities.invokeAndWait {
                val renderer=PdfDesktopHost(BookRecord(newBookId(),"Selection",BookFormat.PDF,file,Instant.now()),{}, {_,_->ready.countDown()})
                host=renderer;frame=JFrame("CloudReader isolated PDF check").apply{add(renderer.component);setSize(800,900);isVisible=true}
            }
            assertTrue("The PDF must finish native rendering",ready.await(20,TimeUnit.SECONDS))
            SwingUtilities.invokeAndWait {
                val panel=(host!!.component as javax.swing.JScrollPane).viewport.view
                val now=System.currentTimeMillis()
                panel.dispatchEvent(java.awt.event.MouseEvent(panel,java.awt.event.MouseEvent.MOUSE_PRESSED,now,java.awt.event.InputEvent.BUTTON1_DOWN_MASK,90,65,1,false,java.awt.event.MouseEvent.BUTTON1))
                panel.dispatchEvent(java.awt.event.MouseEvent(panel,java.awt.event.MouseEvent.MOUSE_DRAGGED,now+50,java.awt.event.InputEvent.BUTTON1_DOWN_MASK,400,120,0,false,java.awt.event.MouseEvent.NOBUTTON))
            }
            val selected=AtomicReference("");val done=CountDownLatch(1)
            host!!.selection{selected.set(it);done.countDown()}
            assertTrue(done.await(5,TimeUnit.SECONDS));assertEquals("Selected passage",selected.get().trim())
        } finally { SwingUtilities.invokeAndWait{host?.close();frame?.dispose()};root.toFile().deleteRecursively() }
    }
    @Test fun nativeWebKitRendersTurnsAndRestoresReflow() = verifyRestore(BookFormat.EPUB,"reflow:0:0.4",0)
    @Test fun legacyTxtOffsetRestoresTheSourcePassage() = verifyRestore(BookFormat.TXT,null,7000)

    private fun verifyRestore(format:BookFormat,locator:String?,textOffset:Int) {
        assumeTrue("Enable on a graphical target OS or Xvfb",System.getenv("CLOUDREADER_GUI_TESTS")=="1")
        val root=Files.createTempDirectory("desktop-native-reader").toFile()
        val file=java.io.File(root,"chapter.html")
        file.writeText("<html><body>"+(1..160).joinToString(""){"<p>Passage $it. This is original test text for native WebKit pagination and reading restoration.</p>"}+"</body></html>")
        val publication=PreparedPublication(root,listOf(PublicationChapter("Chapter",file)))
        val book=BookRecord(newBookId(),"Reader test",format,file.toPath(),Instant.now(),textOffset=textOffset,localLocation=locator)
        val fraction=AtomicReference(0.0);val status=AtomicReference("")
        val ready=CountDownLatch(1)
        var frame:JFrame?=null
        var host:ReflowDesktopHost?=null
        val reports=java.util.concurrent.atomic.AtomicInteger()
        try {
            SwingUtilities.invokeAndWait {
                // Initialize Swing before creating the embedded JavaFX toolkit.
                val window=JFrame("CloudReader isolated reader check")
                val reader=ReflowDesktopHost(book,publication,{status.set(it)},{progress,_->fraction.set(progress);reports.incrementAndGet();ready.countDown()},{})
                host=reader
                frame=window.apply{add(reader.component);setSize(1000,740);isVisible=true}
            }
            assertTrue("The native reader must report its rendered location",ready.await(30,TimeUnit.SECONDS))
            try{await("Restored progress should remain beyond the opening page"){fraction.get()>.15}}
            catch(failure:AssertionError){
                val inspected=CountDownLatch(1)
                javafx.application.Platform.runLater{
                    try{
                        val field=ReflowDesktopHost::class.java.getDeclaredField("web").apply{isAccessible=true}
                        val web=field.get(host) as javafx.scene.web.WebView
                        println(web.engine.executeScript("JSON.stringify({width:innerWidth,height:innerHeight,x:scrollX,y:scrollY,scrollWidth:document.scrollingElement.scrollWidth,scrollHeight:document.scrollingElement.scrollHeight,textLength:document.body.textContent.length,first:document.body.firstElementChild.getBoundingClientRect().left})"))
                    }finally{inspected.countDown()}
                }
                inspected.await(5,TimeUnit.SECONDS);throw failure
            }
            val restored=fraction.get()
            SwingUtilities.invokeAndWait{host!!.next()}
            await("A real next-page operation must advance WebKit"){fraction.get()>restored+.01}
            val afterTurn=fraction.get()
            val beforeReflow=reports.get()
            SwingUtilities.invokeAndWait{host!!.appearance(ReadingAppearance(fontSize=24,layout=ReaderLayout.SPREAD))}
            await("Reflow should retain the same passage range"){reports.get()>beforeReflow && kotlin.math.abs(fraction.get()-afterTurn)<.12 && status.get().contains("Page")}
        } finally {
            SwingUtilities.invokeAndWait { host?.close();frame?.dispose() }
            root.deleteRecursively()
        }
    }
    private fun await(message:String,condition:()->Boolean){
        val until=System.nanoTime()+TimeUnit.SECONDS.toNanos(15)
        while(System.nanoTime()<until){if(condition())return;Thread.sleep(50)}
        assertTrue(message,condition())
    }
}
