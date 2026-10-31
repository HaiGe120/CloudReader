package io.github.haige120.cloudreader

import android.content.Intent
import android.graphics.BitmapFactory
import android.os.Bundle
import android.webkit.*
import androidx.activity.compose.setContent
import androidx.fragment.app.FragmentActivity
import androidx.compose.foundation.Image
import androidx.compose.foundation.gestures.rememberTransformableState
import androidx.compose.foundation.gestures.detectHorizontalDragGestures
import androidx.compose.foundation.gestures.transformable
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.Alignment
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.compose.ui.input.pointer.pointerInput
import androidx.lifecycle.lifecycleScope
import io.github.haige120.cloudreader.core.reader.*
import io.github.haige120.cloudreader.core.application.*
import io.github.haige120.cloudreader.domain.BookRecord
import io.github.haige120.cloudreader.data.toDomain
import io.github.haige120.cloudreader.ui.*
import kotlinx.coroutines.*
import java.io.File

/** FB2/CBZ host using the same preparation, reader script and controls as Windows/Linux. */
class PublicationReaderActivity:FragmentActivity(){
    private val app get()=application as CloudReaderApp
    private var web:WebView?=null
    private var prepared:PreparedPublication?=null
    private var book:BookRecord?=null
    private var session:ReaderSession?=null
    private var chapter=0
    private var fraction=0.0
    private var sourceAnchor:Int?=null
    private var onStatus:(String)->Unit={}
    private var onControls:()->Unit={}
    private var currentAppearance=ReadingAppearance()
    private var restoredComicPage:Int?=null
    private var currentComicPage=0
    override fun onCreate(state:Bundle?){
        super.onCreate(state)
        restoredComicPage=state?.getInt("reader.comic",-1)?.takeIf{it>=0}
        val restoredReflow=state?.getString("reader.reflow")
        val id=intent.getStringExtra("book_id")?:run{finish();return}
        lifecycleScope.launch{
            runCatching{
                val record=app.database.libraryDao().book(id)?.toDomain()?:error("Book not found")
                book=record
                currentAppearance=ReadingAppearance(
                    fontSize=app.preferences.get("reader.fontSize")?.toDoubleOrNull()?.toInt()?:20,
                    family=app.preferences.get("reader.font")?.replaceFirstChar{it.uppercase()}?:"Serif",
                    theme=app.preferences.get("reader.theme")?.replaceFirstChar{it.uppercase()}?:"System",
                    layout=runCatching{ReaderLayout.valueOf(app.preferences.get("reader.publication.layout")?:"PAGE")}.getOrDefault(ReaderLayout.PAGE),
                    customBackground=app.preferences.get("reader.customBackground")?:"#fffdf7",
                    customForeground=app.preferences.get("reader.customForeground")?:"#292621",
                ).validated()
                session=ReaderSession(record.id,app.applicationScope,ReaderProgressWriter{bookID,progress,location->
                    app.database.libraryDao().book(bookID)?.toDomain()?.let{app.library.progress(it,progress,location)}
                })
                val publication=withContext(Dispatchers.IO){PublicationLoader.prepare(app.library.fileFor(record)?:error("The local file is missing"),File(cacheDir,"publications"),record.format)}
                prepared=publication
                app.library.opened(record)
                val portablePosition=resumeReflowPosition(record.progress,publication.chapters.size)
                chapter=(restoredReflow?:record.localLocation)?.split(':')?.getOrNull(1)?.toIntOrNull()?.coerceIn(0,maxOf(publication.chapters.lastIndex,0))?:portablePosition.first
                fraction=(restoredReflow?:record.localLocation)?.split(':')?.getOrNull(2)?.toDoubleOrNull()?:portablePosition.second
                sourceAnchor=(restoredReflow?:record.localLocation)?.split(':')?.getOrNull(3)?.toIntOrNull()
                setContent{CloudReaderTheme{Reader(record,publication)}}
            }.onFailure{failure->
                if(failure is CancellationException)throw failure
                setContent{CloudReaderTheme{Column(Modifier.padding(24.dp)){Text(failure.message?:"Could not open this book");TextButton(onClick={finish()}){Text("Back to library")}}}}
            }
        }
    }
    @Composable private fun Reader(record:BookRecord,publication:PreparedPublication){
        var controls by remember{mutableStateOf(true)}
        var appearanceOpen by remember{mutableStateOf(false)}
        var appearance by remember{mutableStateOf(currentAppearance)}
        var status by remember{mutableStateOf("Opening…")}
        var imageIndex by remember{mutableIntStateOf((restoredComicPage?:record.localLocation?.removePrefix("comic:")?.toIntOrNull()?:resumeComicPage(record.progress,publication.images.size)).coerceIn(0,maxOf(publication.images.lastIndex,0)))}
        var scale by remember{mutableFloatStateOf(1f)}
        var pan by remember{mutableStateOf(androidx.compose.ui.geometry.Offset.Zero)}
        val screenWidth=androidx.compose.ui.platform.LocalConfiguration.current.screenWidthDp
        val pageStep=appearance.columns(screenWidth)
        SideEffect{onStatus={status=it};onControls={controls=!controls}}
        fun imageTurn(delta:Int){imageIndex=(imageIndex+delta*pageStep).coerceIn(publication.images.indices);scale=1f;pan=androidx.compose.ui.geometry.Offset.Zero}
        Column(Modifier.fillMaxSize()){
            if(controls)ReaderToolbar(record.title,status,{finish()},
                {if(record.format=="cbz")imageTurn(-1)else web?.evaluateJavascript("reader.turn(-1)",null)},
                {if(record.format=="cbz")imageTurn(1)else web?.evaluateJavascript("reader.turn(1)",null)},
                {appearanceOpen=true},{web?.evaluateJavascript("String(getSelection()).trim() || document.body.innerText.slice(0,18000)"){value->
                    val text=runCatching{org.json.JSONArray("[$value]").getString(0)}.getOrDefault("")
                    setResult(RESULT_OK,Intent().putExtra(PdfReaderActivity.EXTRA_BOOK_ID,record.id).putExtra(PdfReaderActivity.EXTRA_SELECTED_TEXT,text));finish()
                }},{controls=false})
            else TextButton(onClick={controls=true}){Text("Show controls")}
            if(record.format=="cbz"){
                val pages=comicSpread(imageIndex,publication.images.size,appearance,screenWidth)
                val bitmaps by produceState<List<android.graphics.Bitmap>>(emptyList(),pages){
                    value=withContext(Dispatchers.IO){runCatching{pages.map{index->
                        val path=publication.images[index].absolutePath
                        val bounds=BitmapFactory.Options().apply{inJustDecodeBounds=true};BitmapFactory.decodeFile(path,bounds)
                        require(bounds.outWidth>0&&bounds.outHeight>0&&bounds.outWidth.toLong()*bounds.outHeight<=256_000_000L){"Invalid or oversized comic image"}
                        val options=BitmapFactory.Options().apply{inSampleSize=maxOf(1,maxOf(bounds.outWidth,bounds.outHeight)/2048)}
                        BitmapFactory.decodeFile(path,options)?:error("Could not decode the comic image")
                    }}.getOrElse { failure -> onStatus(failure.message?:"Could not decode this comic page");emptyList() }}
                }
                LaunchedEffect(imageIndex,pages){val first=pages.first();currentComicPage=first;status=if(pages.size==2)"Pages ${first+1}–${pages.last()+1} of ${publication.images.size}" else "Page ${first+1} of ${publication.images.size}";session?.checkpoint(if(publication.images.size==1)0.0 else first.toDouble()/(publication.images.size-1),"comic:$first")}
                val transform=rememberTransformableState{zoom,offset,_->scale=(scale*zoom).coerceIn(1f,4f);pan=if(scale>1f)pan+offset else androidx.compose.ui.geometry.Offset.Zero}
                val swipe=Modifier.then(if(scale==1f)Modifier.pointerInput(imageIndex,pageStep){
                    var distance=0f
                    detectHorizontalDragGestures(onDragStart={distance=0f},onDragEnd={if(kotlin.math.abs(distance)>80)imageTurn(if(distance<0)1 else -1)}){_,delta->distance+=delta}
                }else Modifier)
                Row(Modifier.weight(1f).fillMaxWidth().then(swipe).transformable(transform),verticalAlignment=Alignment.CenterVertically){
                    bitmaps.forEachIndexed{index,bitmap->Image(bitmap.asImageBitmap(),contentDescription="Comic page ${pages[index]+1}",modifier=Modifier.weight(1f).fillMaxHeight().graphicsLayer(scaleX=scale,scaleY=scale,translationX=pan.x,translationY=pan.y))}
                    if(pageStep==2&&bitmaps.size==1)Spacer(Modifier.weight(1f))
                }
            }else AndroidView(factory={context->WebView(context).apply{
                web=this
                settings.javaScriptEnabled=true;settings.blockNetworkLoads=true
                settings.allowContentAccess=false;settings.allowFileAccess=true
                settings.setSupportMultipleWindows(false)
                addJavascriptInterface(Bridge(),"nativeReader")
                webViewClient=object:WebViewClient(){
                    override fun shouldOverrideUrlLoading(view:WebView,request:WebResourceRequest):Boolean=
                        request.url.scheme!="file"||runCatching{val file=File(request.url.path.orEmpty());!file.canonicalPath.startsWith(publication.root.canonicalPath+File.separator)||file.extension.lowercase() !in listOf("html","htm","xhtml")}.getOrDefault(true)
                    override fun shouldInterceptRequest(view:WebView,request:WebResourceRequest):WebResourceResponse?{
                        val safe=request.url.scheme=="file"&&runCatching{File(request.url.path.orEmpty()).canonicalPath.startsWith(publication.root.canonicalPath+File.separator)}.getOrDefault(false)
                        return if(safe)null else WebResourceResponse("text/plain","utf-8",java.io.ByteArrayInputStream(ByteArray(0)))
                    }
                    override fun onPageFinished(view:WebView,url:String){view.evaluateJavascript(ReflowScript.script){configure();view.evaluateJavascript(sourceAnchor?.let{"reader.restoreSource($it)"}?:"reader.restore($fraction)",null)}}
                }
                loadUrl(publication.chapters[chapter].file.toURI().toString())
            }},modifier=Modifier.weight(1f).fillMaxWidth())
        }
        if(appearanceOpen)AppearanceDialog(appearance,{next->appearance=next;currentAppearance=next;configure();lifecycleScope.launch{
            app.preferences.set("reader.fontSize",next.fontSize.toString());app.preferences.set("reader.font",next.family.lowercase())
            app.preferences.set("reader.theme",next.theme.lowercase());app.preferences.set("reader.publication.layout",next.layout.name)
            app.preferences.set("reader.customBackground",next.customBackground);app.preferences.set("reader.customForeground",next.customForeground)
        }},{appearanceOpen=false})
    }
    private fun configure(){
        val p=currentAppearance.validated();val dark=p.theme=="Dark"||(p.theme=="System"&&resources.configuration.uiMode and android.content.res.Configuration.UI_MODE_NIGHT_MASK==android.content.res.Configuration.UI_MODE_NIGHT_YES);val bg=if(p.theme=="Custom")p.customBackground else if(dark)"#20211e" else if(p.theme=="Sepia")"#f3e8d0" else "#fffdf7"
        web?.evaluateJavascript("reader.configure(${p.fontSize},'${when(p.family){"Mono"->"monospace";"Sans"->"sans-serif";else->"serif"}}','$bg','${if(p.theme=="Custom")p.customForeground else if(dark)"#eee9df" else "#292621"}','${p.layout.name}')",null)
    }
    inner class Bridge{
        @JavascriptInterface fun location(value:Double,page:Int,pages:Int,anchor:Int){runOnUiThread{
            sourceAnchor=anchor;fraction=value.coerceIn(0.0,1.0);val total=prepared?.chapters?.size?:1
            session?.checkpoint((chapter+fraction)/total,"reflow:$chapter:$fraction:$anchor");onStatus(if(currentAppearance.columns(resources.configuration.screenWidthDp)==2&&page<pages)"Pages $page–${minOf(page+1,pages)} of $pages" else "Page $page of $pages")
        }}
        @JavascriptInterface fun boundary(direction:Int){runOnUiThread{val next=chapter+direction;prepared?.let{if(next in it.chapters.indices){chapter=next;sourceAnchor=null;fraction=if(direction>0)0.0 else 1.0;web?.loadUrl(it.chapters[chapter].file.toURI().toString())}}}}
        @JavascriptInterface fun tap(){runOnUiThread(onControls)}
    }
    override fun onSaveInstanceState(outState:Bundle){outState.putInt("reader.comic",currentComicPage);outState.putString("reader.reflow","reflow:$chapter:$fraction:${sourceAnchor?:0}");super.onSaveInstanceState(outState)}
    override fun onStop(){session?.let{app.applicationScope.launch{it.flush()}};super.onStop()}
    override fun onDestroy(){web?.removeJavascriptInterface("nativeReader");web?.stopLoading();web?.destroy();web=null;prepared?.root?.let{root->app.applicationScope.launch{root.deleteRecursively()}};super.onDestroy()}
}
