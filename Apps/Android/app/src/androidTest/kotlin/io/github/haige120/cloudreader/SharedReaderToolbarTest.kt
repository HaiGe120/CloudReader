package io.github.haige120.cloudreader

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.width
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.*
import io.github.haige120.cloudreader.ui.CloudReaderTheme
import io.github.haige120.cloudreader.ui.ReaderToolbar
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test

class SharedReaderToolbarTest {
    @get:Rule val compose=createComposeRule()
    @Test fun compactReaderKeepsEveryActionVisibleAndOperable(){
        var turns=0
        compose.setContent{CloudReaderTheme{Box(Modifier.width(360.dp)){
            ReaderToolbar("A long book title that must not crowd its controls","Page 2 of 20",{}, {}, {turns++}, {}, {}, {})
        }}}
        listOf("Back","Hide","Previous","Next","Aa","Ask AI").forEach{compose.onNodeWithText(it).assertIsDisplayed()}
        compose.onNodeWithText("Next").performClick()
        compose.runOnIdle{assertEquals(1,turns)}
    }
}
