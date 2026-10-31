package io.github.haige120.cloudreader.desktop

import io.github.haige120.cloudreader.core.reader.*
import java.nio.file.Files
import java.nio.file.Path
import java.time.Instant
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference
import javax.swing.JFrame
import javax.swing.SwingUtilities

/** Runs only with --runtime-check, in a new temporary library, using the bundled JVM. */
internal object PackagedRuntimeCheck {
    fun run(output:Path){
        Files.createDirectories(output)
        val root=Files.createTempDirectory("cloudreader-runtime-check")
        var host:ReflowDesktopHost?=null;var frame:JFrame?=null
        try{
            val pdf=root.resolve("page.pdf")
            org.apache.pdfbox.pdmodel.PDDocument().use{doc->
                doc.addPage(org.apache.pdfbox.pdmodel.PDPage());doc.save(pdf.toFile())
            }
            org.apache.pdfbox.Loader.loadPDF(pdf.toFile()).use{doc->
                check(org.apache.pdfbox.rendering.PDFRenderer(doc).renderImage(0).width>0)
            }
            val chapter=root.resolve("chapter.html").toFile().apply{
                writeText("<html><body>"+(1..150).joinToString(""){"<p>Runtime passage $it. Offline books remain on this device.</p>"}+"</body></html>")
            }
            val ready=CountDownLatch(1);val turned=CountDownLatch(1)
            val progress=AtomicReference(0.0)
            SwingUtilities.invokeAndWait{
                val window=JFrame("CloudReader isolated packaged-runtime check")
                host=ReflowDesktopHost(BookRecord(newBookId(),"Runtime check",BookFormat.EPUB,chapter.toPath(),Instant.now()),
                    PreparedPublication(root.toFile(),listOf(PublicationChapter("Chapter",chapter))),{},
                    {value,_->progress.set(value);ready.countDown();if(value>0)turned.countDown()},{})
                frame=window.apply{add(host!!.component);setSize(900,700);isVisible=true}
            }
            check(ready.await(30,TimeUnit.SECONDS)){"Bundled WebKit did not load a local chapter."}
            SwingUtilities.invokeAndWait{host!!.next()}
            check(turned.await(15,TimeUnit.SECONDS)&&progress.get()>0){"Bundled WebKit did not turn a page."}
            SwingUtilities.invokeAndWait{
                val window=frame!!
                val image=java.awt.image.BufferedImage(window.width,window.height,java.awt.image.BufferedImage.TYPE_INT_RGB)
                image.createGraphics().let{graphics->try{window.paint(graphics)}finally{graphics.dispose()}}
                javax.imageio.ImageIO.write(image,"png",output.resolve("packaged-reader.png").toFile())
            }
            Files.writeString(output.resolve("runtime-check.json"),"""{"pdfRender":true,"webkitLoad":true,"webkitPageTurn":true,"isolatedLibrary":true}""")
        }finally{
            SwingUtilities.invokeAndWait{host?.close();frame?.dispose()}
            root.toFile().deleteRecursively()
        }
    }
}
