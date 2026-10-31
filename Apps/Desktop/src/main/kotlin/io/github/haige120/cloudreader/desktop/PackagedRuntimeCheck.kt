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
            // Exercise the actual shared library shell too, including the bundled
            // Compose/Skiko runtime, rather than validating only reader engines.
            val repository=FileLibraryRepository(root.resolve("library")).apply{seedDemo()}
            val names=AtomicReference("")
            SwingUtilities.invokeAndWait{
                host?.close();host=null;frame?.dispose()
                val compose=androidx.compose.ui.awt.ComposePanel().apply{
                    setContent{CloudReaderDesktopApp(repository,SwingFilePicker(),root.resolve("library"))}
                }
                frame=JFrame("CloudReader isolated packaged-library check").apply{add(compose);setSize(1100,800);isVisible=true}
            }
            val deadline=System.nanoTime()+TimeUnit.SECONDS.toNanos(25)
            while(System.nanoTime()<deadline){
                SwingUtilities.invokeAndWait{
                    fun collect(accessible:javax.accessibility.Accessible):String{
                        val context=accessible.accessibleContext?:return ""
                        return context.accessibleName.orEmpty()+" "+(0 until context.accessibleChildrenCount).joinToString(" "){index->context.getAccessibleChild(index)?.let(::collect).orEmpty()}
                    }
                    names.set(collect(frame!!))
                }
                if(names.get().contains("The Open Shelf")&&names.get().contains("Settings"))break
                Thread.sleep(50)
            }
            check(names.get().contains("The Open Shelf")&&names.get().contains("Settings")){"Bundled shared library UI did not become accessible: ${names.get()}"}
            // GPU-backed Compose panels do not paint into a Java2D image. Only
            // capture the real display on disposable CI desktops, never a user's.
            if(System.getenv("CI")=="true"){
                val bounds=AtomicReference<java.awt.Rectangle>()
                SwingUtilities.invokeAndWait{
                    val window=frame!!
                    val screen=window.graphicsConfiguration.bounds
                    window.setSize(minOf(1100,screen.width-32),minOf(800,screen.height-64))
                    window.setLocation(screen.x+16,screen.y+16);window.toFront()
                    bounds.set(window.bounds)
                }
                val robot=java.awt.Robot();robot.waitForIdle();Thread.sleep(250)
                javax.imageio.ImageIO.write(robot.createScreenCapture(bounds.get()),"png",output.resolve("packaged-library.png").toFile())
            }
            Files.writeString(output.resolve("runtime-check.json"),"""{"pdfRender":true,"webkitLoad":true,"webkitPageTurn":true,"sharedLibraryUI":true,"isolatedLibrary":true}""")
        }finally{
            SwingUtilities.invokeAndWait{host?.close();frame?.dispose()}
            root.toFile().deleteRecursively()
        }
    }
}
