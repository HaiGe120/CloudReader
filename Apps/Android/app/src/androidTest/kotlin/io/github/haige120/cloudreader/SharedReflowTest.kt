package io.github.haige120.cloudreader

import android.content.Intent
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.test.core.app.ActivityScenario
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import io.github.haige120.cloudreader.core.reader.PublicationLoader
import io.github.haige120.cloudreader.core.reader.ReflowScript
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/** Opens only a temporary prepared FB2; never reads the real library or provider settings. */
@RunWith(AndroidJUnit4::class)
class SharedReflowTest {
    @Test fun preparedFb2RendersAndTurnsPagesWithTheSharedScript() {
        val context=ApplicationProvider.getApplicationContext<android.content.Context>()
        val root=File(context.cacheDir,"shared-reader-${java.util.UUID.randomUUID()}").apply{mkdirs()}
        val file=File(root,"book.fb2").apply{writeText("<FictionBook><body><section><title><p>Shared chapter</p></title>"+(1..100).joinToString(""){"<p>Passage $it. Reader content for deterministic page navigation, appearance and source preservation.</p>"}+"</section></body></FictionBook>")}
        val publication=PublicationLoader.prepare(file,File(root,"prepared"))
        lateinit var web:WebView
        val ready=CountDownLatch(1)
        try {
            ActivityScenario.launch<EpubReaderActivity>(Intent(context,EpubReaderActivity::class.java)).use{scenario->
                scenario.onActivity{activity->
                    web=WebView(activity).apply{
                        settings.javaScriptEnabled=true;settings.blockNetworkLoads=true
                        settings.allowFileAccess=true;settings.allowContentAccess=false
                        webViewClient=object:WebViewClient(){override fun onPageFinished(view:WebView,url:String){
                            view.evaluateJavascript("window.nativeReader={location:function(p,page,pages,anchor){window.reportedAnchor=anchor;},boundary:function(){},tap:function(){}};"+ReflowScript.script){
                                view.evaluateJavascript("reader.configure(20,'serif','#fffdf7','#292621','PAGE')"){ready.countDown()}
                            }
                        }}
                    }
                    activity.setContentView(web)
                    web.loadUrl(publication.chapters.single().file.toURI().toString())
                }
                assertTrue("Prepared FB2 must render",ready.await(20,TimeUnit.SECONDS))
                fun evaluate(script:String):String{
                    val done=CountDownLatch(1);var result=""
                    scenario.onActivity{web.evaluateJavascript(script){result=it;done.countDown()}}
                    assertTrue(done.await(5,TimeUnit.SECONDS));return result
                }
                assertTrue(evaluate("document.body.innerText").contains("Shared chapter"))
                assertEquals("true",evaluate("document.scrollingElement.scrollWidth > innerWidth"))
                assertEquals("true",evaluate("reader.turn(1);scrollX>0"))
                assertEquals("true",evaluate("reader.turn(-1);scrollX===0"))
                // Queue two reflows around an explicit restore in the same frame.
                // An older configure callback must not overwrite the requested passage.
                evaluate("reader.configure(20,'serif','#fffdf7','#292621','PAGE');reader.restoreSource(5000);reader.configure(24,'serif','#fffdf7','#292621','PAGE')")
                val deadline=System.nanoTime()+TimeUnit.SECONDS.toNanos(10)
                var restored=false
                while(System.nanoTime()<deadline&&!restored){
                    restored=evaluate("window.reportedAnchor>3500 && scrollX>0")=="true"
                    if(!restored)Thread.sleep(50)
                }
                assertTrue("A stale reflow callback must not reset the restored passage",restored)
                scenario.onActivity{web.destroy()}
            }
        } finally { root.deleteRecursively() }
    }
}
