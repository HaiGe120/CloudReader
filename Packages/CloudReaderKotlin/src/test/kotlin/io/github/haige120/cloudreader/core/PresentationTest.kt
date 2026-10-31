package io.github.haige120.cloudreader.core

import io.github.haige120.cloudreader.core.application.*
import io.github.haige120.cloudreader.core.model.BookRecord
import org.junit.Assert.*
import org.junit.Test

class PresentationTest {
    @Test fun portablePdfResumeMatchesAppleAndAndroidPageFractions(){
        assertEquals(0,resumePdfPage(0.0,5));assertEquals(0,resumePdfPage(.2,5))
        assertEquals(3,resumePdfPage(.8,5));assertEquals(4,resumePdfPage(1.0,5))
        assertEquals(0,resumePdfPage(Double.NaN,5));assertEquals(0,resumePdfPage(.5,0))
    }
    @Test fun portableComicResumeRetainsEndpointsAndMiddlePage(){
        assertEquals(0,resumeComicPage(0.0,5));assertEquals(2,resumeComicPage(.5,5))
        assertEquals(4,resumeComicPage(1.0,5));assertEquals(0,resumeComicPage(Double.POSITIVE_INFINITY,5))
    }
    @Test fun portableReflowResumeSplitsGlobalProgressAcrossChapters(){
        assertEquals(1,resumeReflowPosition(.8,2).first)
        assertEquals(.6,resumeReflowPosition(.8,2).second,0.00001)
        assertEquals(1 to 1.0,resumeReflowPosition(1.0,2))
        assertEquals(0 to 0.0,resumeReflowPosition(Double.NaN,2))
    }
    private fun book(id:String,opened:Double?=null,favorite:Boolean=false)=BookRecord(id,"Book $id",fileName="$id.txt",format="txt",addedAt=1.0,lastOpenedAt=opened,isBookmarked=favorite,modifiedAt=1.0)
    @Test fun continueAndFilterShareTheSamePolicy(){
        val books=listOf(book("new"),book("old",2.0,true),book("latest",3.0))
        val state=LibraryPresentation(books,"old",true)
        assertEquals("latest",state.continuing?.id);assertEquals(listOf("old"),state.visible.map{it.id})
    }
    @Test fun spreadsFallBackOnCompactWindowsWithoutChangingThePreference(){
        val appearance=ReadingAppearance(layout=ReaderLayout.SPREAD)
        assertEquals(1,appearance.columns(699));assertEquals(2,appearance.columns(700));assertEquals(ReaderLayout.SPREAD,appearance.layout)
    }
    @Test fun comicSpreadsKeepOddLastPageAndCompactFallback(){
        val style=ReadingAppearance(layout=ReaderLayout.SPREAD)
        assertEquals(listOf(0,1),comicSpread(1,5,style,900))
        assertEquals(listOf(4),comicSpread(4,5,style,900))
        assertEquals(listOf(3),comicSpread(3,5,style,400))
    }
}
