package io.github.haige120.cloudreader.desktop

import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.awt.SwingPanel
import androidx.compose.ui.unit.dp
import io.github.haige120.cloudreader.core.application.*
import io.github.haige120.cloudreader.core.reader.*
import io.github.haige120.cloudreader.ui.*
import javafx.application.Platform
import javafx.embed.swing.JFXPanel
import javafx.scene.Scene
import javafx.scene.web.WebView
import javafx.concurrent.Worker
import netscape.javascript.JSObject
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.apache.pdfbox.Loader
import org.apache.pdfbox.rendering.PDFRenderer
import org.apache.pdfbox.text.PDFTextStripper
import java.awt.BorderLayout
import java.awt.Color
import java.nio.file.Path
import javax.swing.*
import java.util.concurrent.atomic.AtomicBoolean

@Composable
fun DesktopReader(book: BookRecord, cache: Path, settings: DesktopSettings, onClose: () -> Unit,
    onPosition: (Double,String) -> Unit, onAsk: (String) -> Unit) {
    var failure by remember(book.id) { mutableStateOf<String?>(null) }
    var controls by remember { mutableStateOf(true) }
    var appearanceOpen by remember { mutableStateOf(false) }
    var appearance by remember { mutableStateOf(ReadingAppearance(
        fontSize = settings.get("reader.fontSize","20").toIntOrNull() ?: 20,
        family = settings.get("reader.fontFamily","Serif"), theme = settings.get("reader.theme","System"),
        layout = runCatching { ReaderLayout.valueOf(settings.get("reader.layout","PAGE")) }.getOrDefault(ReaderLayout.PAGE),
        customBackground=settings.get("reader.customBackground","#fffdf7"),customForeground=settings.get("reader.customForeground","#292621"))) }
    var status by remember(book.id) { mutableStateOf("Opening…") }
    var host by remember(book.id) { mutableStateOf<DesktopReaderHost?>(null) }
    val systemDark = androidx.compose.foundation.isSystemInDarkTheme()
    val prepared by produceState<Result<PreparedPublication>?>(null, book.id) {
        value = withContext(Dispatchers.IO) { runCatching {
            when (book.format) {
                BookFormat.EPUB, BookFormat.FB2, BookFormat.CBZ -> PublicationLoader.prepare(book.sourcePath.toFile(), cache.toFile(), book.format.extension)
                BookFormat.TXT -> {
                    val text = TxtContentReader().open(book).use { it.text }
                    val dir = java.nio.file.Files.createTempDirectory(cache, "text-").toFile()
                    val file = java.io.File(dir,"text.html")
                    val escaped = text.replace("&","&amp;").replace("<","&lt;").replace(">","&gt;")
                    file.writeText("<html><head><meta charset=\"utf-8\"></head><body><article style=\"white-space:pre-wrap\">$escaped</article></body></html>")
                    PreparedPublication(dir, listOf(PublicationChapter(book.title,file)))
                }
                BookFormat.PDF -> PreparedPublication(cache.toFile())
                else -> error("${book.format} is stored in your library. Its reader is not enabled in the current iOS reference either.")
            }
        } }
    }
    Column(Modifier.fillMaxSize()) {
        if (controls) ReaderToolbar(book.title,status,onClose,{ host?.previous() },{ host?.next() },
            { appearanceOpen = true },{ host?.selection(onAsk) },{ controls = false })
        else Row { TextButton(onClick = { controls = true }) { Text("Show controls") } }
        failure?.let { Text(it, color = MaterialTheme.colorScheme.error, modifier = Modifier.padding(20.dp)) }
        val result = prepared
        if (result == null) Box(Modifier.weight(1f).fillMaxWidth(), contentAlignment = Alignment.Center) { CircularProgressIndicator() }
        else if (result.isFailure) Text(result.exceptionOrNull()?.message ?: "Could not open this book.", modifier = Modifier.padding(20.dp))
        else {
            val publication = result.getOrThrow()
            val reader = remember(book.id,publication) {
                when (book.format) {
                    BookFormat.PDF -> PdfDesktopHost(book, { status = it },onPosition)
                    BookFormat.CBZ -> ComicDesktopHost(book,publication,{ status = it },onPosition)
                    else -> ReflowDesktopHost(book,publication,{ status = it },onPosition,{ controls = !controls })
                }
            }
            DisposableEffect(reader) { host = reader; onDispose { reader.close(); if (book.format != BookFormat.PDF) publication.root.deleteRecursively() } }
            SwingPanel(factory = { reader.component }, modifier = Modifier.weight(1f).fillMaxWidth(), update = {
                reader.appearance(if (appearance.theme == "System") appearance.copy(theme = if (systemDark) "Dark" else "Light") else appearance)
            })
        }
    }
    if (appearanceOpen) AppearanceDialog(appearance, { next ->
        appearance = next
        settings.save(mapOf("reader.fontSize" to next.fontSize.toString(), "reader.fontFamily" to next.family, "reader.theme" to next.theme, "reader.layout" to next.layout.name,"reader.customBackground" to next.customBackground,"reader.customForeground" to next.customForeground))
    }, { appearanceOpen = false })
}

internal interface DesktopReaderHost : AutoCloseable {
    val component: JComponent
    fun next()
    fun previous()
    fun appearance(value: ReadingAppearance)
    fun selection(callback: (String) -> Unit)
}

/** JavaFX WebKit renders local prepared chapters; publisher scripts and remote resources are removed. */
internal class ReflowDesktopHost(private val book: BookRecord, private val publication: PreparedPublication,
    private val status: (String)->Unit, private val position: (Double,String)->Unit, private val toggle: ()->Unit) : DesktopReaderHost {
    private val panel = JFXPanel()
    override val component: JComponent get() = panel
    private var web: WebView? = null
    private val portablePosition=resumeReflowPosition(book.progress,publication.chapters.size)
    private var chapter = book.localLocation?.split(':')?.getOrNull(1)?.toIntOrNull()?.coerceIn(publication.chapters.indices) ?: portablePosition.first
    private var fraction = book.localLocation?.split(':')?.getOrNull(2)?.toDoubleOrNull()?.coerceIn(0.0,1.0) ?: portablePosition.second
    private var sourceAnchor:Int? = if (book.format == BookFormat.TXT) book.localLocation?.removePrefix("txt:")?.toIntOrNull() ?: book.textOffset.takeIf{it>0} else book.localLocation?.split(':')?.getOrNull(3)?.toIntOrNull()
    private var currentAppearance = ReadingAppearance()
    private var loaded = false
    private val closed = AtomicBoolean(false)
    val bridge = Bridge()
    init { Platform.setImplicitExit(false); Platform.runLater {
        if (closed.get()) return@runLater
        val view = WebView(); web = view
        view.engine.setCreatePopupHandler { null }
        view.engine.setConfirmHandler { false }
        view.engine.loadWorker.stateProperty().addListener { _,_,state ->
            if (state == Worker.State.SUCCEEDED) {
                loaded = true
                val window = view.engine.executeScript("window") as JSObject
                window.setMember("nativeReader",bridge)
                view.engine.executeScript(SCRIPT)
                configure()
                val anchor=sourceAnchor
                view.engine.executeScript(if(anchor!=null)"reader.restoreSource($anchor)" else "reader.restore($fraction)")
            }
        }
        view.engine.locationProperty().addListener { _,_,location ->
            val allowed = publication.chapters.any { location.substringBefore('#') == it.file.toURI().toString() }
            if (location.isNotEmpty() && location != "about:blank" && !allowed) view.engine.loadWorker.cancel()
        }
        panel.scene = Scene(view); load()
    } }
    private fun load() { loaded = false; web?.engine?.load(publication.chapters[chapter].file.toURI().toString()) }
    private fun configure() {
        val p = currentAppearance.validated()
        // The Compose host resolves System appearance. Never initialize Swing's
        // look-and-feel from the JavaFX thread (it can deadlock AppKit startup).
        val dark = p.theme == "Dark"
        val bg = if(p.theme == "Custom") p.customBackground else if (dark) "#20211e" else if(p.theme == "Sepia") "#f3e8d0" else "#fffdf7"
        val fg = if(p.theme == "Custom") p.customForeground else if (dark) "#eee9df" else "#292621"
        val font = when(p.family) { "Mono" -> "monospace"; "Sans" -> "sans-serif"; else -> "serif" }
        web?.engine?.executeScript("reader.configure(${p.fontSize},'$font','$bg','$fg','${p.layout.name}')")
    }
    override fun next() { Platform.runLater { if (loaded) web?.engine?.executeScript("reader.turn(1)") } }
    override fun previous() { Platform.runLater { if (loaded) web?.engine?.executeScript("reader.turn(-1)") } }
    override fun appearance(value: ReadingAppearance) { if (value != currentAppearance) { currentAppearance = value; Platform.runLater { if (loaded) configure() } } }
    override fun selection(callback: (String)->Unit) { Platform.runLater {
        val text = web?.engine?.executeScript("String(getSelection()).trim() || document.body.innerText.slice(0,18000)")?.toString().orEmpty().take(18000)
        SwingUtilities.invokeLater { callback(text) }
    } }
    override fun close() { closed.set(true); Platform.runLater { web?.engine?.load(null); panel.scene = null; web = null } }
    inner class Bridge {
        fun location(value: Double, page: Int, pages: Int, anchor:Int) {
            sourceAnchor=anchor
            fraction = value.coerceIn(0.0,1.0)
            val part = chapter; val progress = (part + fraction) / publication.chapters.size
            val caption=if(currentAppearance.columns(panel.width)==2&&page<pages)"Pages $page–${minOf(page+1,pages)} of $pages" else "Page $page of $pages"
            val locator=if(book.format==BookFormat.TXT)"txt:$anchor" else "reflow:$part:$fraction:$anchor"
            SwingUtilities.invokeLater { status("${publication.chapters[part].title} · $caption"); position(progress,locator) }
        }
        fun boundary(direction: Int) {
            val next = chapter + direction
            if (next in publication.chapters.indices) { chapter = next; sourceAnchor=null;fraction = if(direction > 0) 0.0 else 1.0; load() }
        }
        fun tap() { SwingUtilities.invokeLater(toggle) }
    }
    companion object {
        private val SCRIPT = ReflowScript.script
    }
}

internal class PdfDesktopHost(private val book: BookRecord,private val status:(String)->Unit,private val position:(Double,String)->Unit):DesktopReaderHost {
    private val panel = SelectablePdfPage()
    override val component:JComponent = JScrollPane(panel)
    private var document: org.apache.pdfbox.pdmodel.PDDocument? = null
    private var page = book.localLocation?.removePrefix("pdf:")?.toIntOrNull() ?: 0
    private val worker = java.util.concurrent.Executors.newSingleThreadExecutor { Thread(it,"CloudReader PDF").apply { isDaemon=true } }
    private var zoom = 1f
    @Volatile private var style=ReadingAppearance()
    @Volatile private var viewportWidth=0
    private val closed = AtomicBoolean(false)
    init {
        component.addComponentListener(object:java.awt.event.ComponentAdapter(){override fun componentResized(event:java.awt.event.ComponentEvent){
            viewportWidth=component.width
            if(!closed.get())worker.submit{render()}
        }})
        worker.submit { runCatching {
            document=Loader.loadPDF(book.sourcePath.toFile())
            require(document!!.numberOfPages>0){"This PDF has no pages."}
            page=(book.localLocation?.removePrefix("pdf:")?.toIntOrNull()?:resumePdfPage(book.progress,document!!.numberOfPages)).coerceIn(0,document!!.numberOfPages-1)
            render()
        }.onFailure { SwingUtilities.invokeLater { panel.error=it.message;panel.repaint() } } }
    }
    private fun render() {
        val doc=document ?: return
        if(closed.get())return
        val visible=comicSpread(page,doc.numberOfPages,style,viewportWidth)
        val current=visible.first()
        val boxes=visible.map{doc.getPage(it).cropBox}
        require(boxes.all{it.width>0&&it.height>0}){"Invalid PDF page dimensions"}
        val dpi=minOf(96f*zoom,72f*3000/maxOf(boxes.sumOf{it.width.toDouble()}.toFloat(),boxes.maxOf{it.height}))
        val ratio=dpi/72f
        val images=visible.map{PDFRenderer(doc).renderImageWithDPI(it,dpi)}
        val image=java.awt.image.BufferedImage(images.sumOf{it.width}+16*(images.size-1),images.maxOf{it.height},java.awt.image.BufferedImage.TYPE_INT_RGB)
        val background=when(style.theme){"Dark"->Color(0x20211e);"Sepia"->Color(0xf3e8d0);"Custom"->Color.decode(style.validated().customBackground);else->Color(0xfffdf7)}
        val glyphs=mutableListOf<PdfGlyph>()
        var x=0
        image.createGraphics().let{graphics->try{
            graphics.color=background;graphics.fillRect(0,0,image.width,image.height)
            visible.forEachIndexed{index,pdfPage->
                val shift=x/ratio
                graphics.drawImage(images[index],x,0,null)
                object:PDFTextStripper(){
                    init{startPage=pdfPage+1;endPage=pdfPage+1;sortByPosition=true}
                    override fun writeString(text:String,textPositions:MutableList<org.apache.pdfbox.text.TextPosition>){
                        textPositions.forEach{p->glyphs+=PdfGlyph(p.unicode,java.awt.geom.Rectangle2D.Float(shift+p.xDirAdj,p.yDirAdj-p.heightDir,p.widthDirAdj,maxOf(p.heightDir,1f)))}
                        super.writeString(text,textPositions)
                    }
                }.getText(doc)
                x+=images[index].width+16
            }
        }finally{graphics.dispose()}}
        SwingUtilities.invokeLater { if(!closed.get()){
            panel.background=background;(component as JScrollPane).viewport.background=background
            panel.showPage(image,glyphs,ratio,current)
            status(if(visible.size==2)"Pages ${current+1}–${visible.last()+1} of ${doc.numberOfPages}" else "Page ${current+1} of ${doc.numberOfPages}")
            position((visible.last()+1.0)/doc.numberOfPages,"pdf:$current")
        } }
    }
    override fun next(){worker.submit { document?.let{val step=style.columns(viewportWidth);page=(page/step*step+step).coerceAtMost(it.numberOfPages-1);render()} }}
    override fun previous(){worker.submit { val step=style.columns(viewportWidth);page=(page/step*step-step).coerceAtLeast(0);render() }}
    override fun appearance(value:ReadingAppearance){ if(value!=style){style=value.validated();zoom=style.fontSize/20f;worker.submit{render()}} }
    override fun selection(callback:(String)->Unit){ worker.submit { document?.let { doc -> val text=panel.selectedText.ifBlank{PDFTextStripper().apply { startPage=page+1;endPage=page+1 }.getText(doc)}.take(18000);SwingUtilities.invokeLater{callback(text)} } } }
    override fun close(){closed.set(true);worker.submit{document?.close()};worker.shutdown()}
}

private data class PdfGlyph(val text:String,val bounds:java.awt.geom.Rectangle2D.Float)
private class SelectablePdfPage:JPanel(){
    private var image:java.awt.image.BufferedImage?=null
    private var glyphs:List<PdfGlyph> = emptyList()
    private var scale=1f
    private var pageToken=-1
    private var start:java.awt.Point?=null
    private var selected=emptySet<Int>()
    @Volatile var selectedText=""
        private set
    var error:String?="Opening PDF…"
    init{
        background=Color.WHITE
        isFocusable=true
        cursor=java.awt.Cursor.getPredefinedCursor(java.awt.Cursor.TEXT_CURSOR)
        toolTipText="Drag across PDF text to select a passage for Ask AI."
        val copy=object:AbstractAction("Copy") { override fun actionPerformed(event:java.awt.event.ActionEvent) {
            if(selectedText.isNotBlank())java.awt.Toolkit.getDefaultToolkit().systemClipboard.setContents(java.awt.datatransfer.StringSelection(selectedText),null)
        } }
        componentPopupMenu=JPopupMenu().apply{add(JMenuItem(copy))}
        getInputMap(WHEN_FOCUSED).put(KeyStroke.getKeyStroke(java.awt.event.KeyEvent.VK_C,java.awt.Toolkit.getDefaultToolkit().menuShortcutKeyMaskEx),"copy-selection")
        actionMap.put("copy-selection",copy)
        val mouse=object:java.awt.event.MouseAdapter(){
            override fun mousePressed(event:java.awt.event.MouseEvent){requestFocusInWindow();start=event.point;selected=emptySet();selectedText="";repaint()}
            override fun mouseDragged(event:java.awt.event.MouseEvent){
                val begin=start?:return
                val rectangle=java.awt.geom.Rectangle2D.Float(minOf(begin.x,event.x)/scale,minOf(begin.y,event.y)/scale,kotlin.math.abs(event.x-begin.x)/scale,kotlin.math.abs(event.y-begin.y)/scale)
                selected=glyphs.indices.filter{glyphs[it].bounds.intersects(rectangle)}.toSet()
                var previous:PdfGlyph?=null
                selectedText=buildString{selected.sorted().forEach{index->val glyph=glyphs[index];previous?.let{if(kotlin.math.abs(glyph.bounds.y-it.bounds.y)>maxOf(it.bounds.height,glyph.bounds.height))append('\n')};append(glyph.text);previous=glyph}}
                repaint()
            }
        }
        addMouseListener(mouse);addMouseMotionListener(mouse)
    }
    fun showPage(next:java.awt.image.BufferedImage,text:List<PdfGlyph>,ratio:Float,token:Int){
        image=next;glyphs=text;scale=ratio;error=null
        if(token!=pageToken){selected=emptySet();selectedText="";pageToken=token}
        preferredSize=java.awt.Dimension(next.width,next.height);revalidate();repaint()
    }
    override fun paintComponent(graphics:java.awt.Graphics){
        super.paintComponent(graphics)
        image?.let{graphics.drawImage(it,0,0,null)}
        val g=graphics.create() as java.awt.Graphics2D
        try{
            g.color=Color(75,125,220,90)
            selected.forEach{index->glyphs.getOrNull(index)?.bounds?.let{r->g.fill(java.awt.geom.Rectangle2D.Float(r.x*scale,r.y*scale,r.width*scale,r.height*scale))}}
            error?.let{g.color=Color.DARK_GRAY;g.drawString(it,20,30)}
        }finally{g.dispose()}
    }
}

internal class ComicDesktopHost(private val book:BookRecord,private val publication:PreparedPublication,private val status:(String)->Unit,private val position:(Double,String)->Unit):DesktopReaderHost {
    private val canvas=JPanel(java.awt.GridLayout(1,1,16,0))
    override val component:JComponent=JScrollPane(canvas)
    private var page=book.localLocation?.removePrefix("comic:")?.toIntOrNull()?.coerceIn(publication.images.indices) ?: resumeComicPage(book.progress,publication.images.size)
    private var style=ReadingAppearance()
    private var zoom=1.0
    private val closed=AtomicBoolean(false)
    private val worker=java.util.concurrent.Executors.newSingleThreadExecutor { Thread(it,"CloudReader comic").apply{isDaemon=true} }
    init{
        component.addComponentListener(object:java.awt.event.ComponentAdapter(){override fun componentResized(event:java.awt.event.ComponentEvent){render()}})
        component.addMouseWheelListener { event ->
            if(event.isControlDown){zoom=(zoom*(if(event.wheelRotation<0)1.15 else .87)).coerceIn(.5,4.0);render();event.consume()}
            else if(event.isShiftDown){if(event.wheelRotation>0)next()else previous();event.consume()}
        }
        render()
    }
    private fun pages()=comicSpread(page,publication.images.size,style,component.width)
    private fun render(){
        if(closed.get())return
        val visible=pages();val requested=page;val current=visible.first();val zoomNow=zoom
        val columnCount=style.columns(component.width)
        val targetWidth=maxOf(150,component.width/columnCount-24)
        worker.submit{
            val result=runCatching{visible.map{index->
                javax.imageio.ImageIO.createImageInputStream(publication.images[index]).use{ input ->
                    val reader=javax.imageio.ImageIO.getImageReaders(input).asSequence().firstOrNull()?:error("Unsupported comic image")
                    try{
                        reader.input=input;require(reader.getWidth(0).toLong()*reader.getHeight(0)<=256_000_000L){"Comic image exceeds the decode limit"}
                        val sample=maxOf(1,maxOf(reader.getWidth(0),reader.getHeight(0))/2048)
                        val param=reader.defaultReadParam.apply{setSourceSubsampling(sample,sample,0,0)}
                        val image=reader.read(0,param)
                        val width=(minOf(image.width,targetWidth)*zoomNow).toInt().coerceAtLeast(1)
                        val height=(image.height.toDouble()/image.width*width).toInt().coerceAtLeast(1)
                        ImageIcon(image.getScaledInstance(width,height,java.awt.Image.SCALE_SMOOTH))
                    }finally{reader.dispose()}
                }
            }}
            SwingUtilities.invokeLater{
                if(closed.get()||requested!=page)return@invokeLater
                canvas.removeAll();canvas.layout=java.awt.GridLayout(1,columnCount,16,0)
                result.onSuccess{icons->icons.forEach{canvas.add(JLabel(it,SwingConstants.CENTER))};if(columnCount==2&&icons.size==1)canvas.add(JPanel().apply{isOpaque=false})
                    status(if(visible.size==2)"Pages ${visible.first()+1}–${visible.last()+1} of ${publication.images.size}" else "Page ${current+1} of ${publication.images.size}")
                    position(if(publication.images.size==1)0.0 else current.toDouble()/(publication.images.size-1),"comic:$current")
                }.onFailure{failure->canvas.add(JLabel(failure.message))}
                canvas.revalidate();canvas.repaint()
            }
        }
    }
    override fun next(){page=(pages().first()+style.columns(component.width)).coerceAtMost(publication.images.lastIndex);render()}
    override fun previous(){page=(pages().first()-style.columns(component.width)).coerceAtLeast(0);render()}
    override fun appearance(value:ReadingAppearance){if(style!=value){style=value;render()}}
    override fun selection(callback:(String)->Unit){callback("")}
    override fun close(){closed.set(true);worker.shutdownNow()}
}
