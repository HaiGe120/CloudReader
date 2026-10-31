package io.github.haige120.cloudreader

import android.graphics.Rect
import android.os.SystemClock
import android.view.View
import android.view.ViewGroup
import android.widget.ScrollView
import android.widget.TextView
import androidx.activity.ComponentActivity
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.test.espresso.Espresso.onView
import androidx.test.espresso.Espresso.pressBack
import androidx.test.espresso.UiController
import androidx.test.espresso.ViewAction
import androidx.test.espresso.action.CoordinatesProvider
import androidx.test.espresso.action.GeneralClickAction
import androidx.test.espresso.action.Press
import androidx.test.espresso.action.Tap
import androidx.test.espresso.action.ViewActions.click
import androidx.test.espresso.action.ViewActions.swipeLeft
import androidx.test.espresso.action.ViewActions.swipeUp
import androidx.test.espresso.matcher.ViewMatchers.isRoot
import androidx.test.espresso.matcher.ViewMatchers.isAssignableFrom
import androidx.test.espresso.matcher.ViewMatchers.isDisplayed
import androidx.test.espresso.matcher.ViewMatchers.withText
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.hamcrest.Matcher
import org.hamcrest.Matchers.allOf

/** UI-only fixtures: no application container, database, preferences or library files. */
@RunWith(AndroidJUnit4::class)
class TextReaderChromeTest {
    @get:Rule val compose = createAndroidComposeRule<ComponentActivity>()
    private val sample = (1..500).joinToString("\n\n") { "Passage $it: This reading fixture has enough selectable words to exercise scrolling and horizontal pages." }

    @Test fun appearanceIsCollapsedAndBackClosesSheetBeforeBook() {
        val settings = mutableStateOf(TextReaderAppearance())
        val changes = mutableMapOf<String, String>()
        var closes = 0
        compose.setContent {
            MaterialTheme {
                TextReaderContent(
                    bookId = "appearance-fixture", title = "Test book", contents = sample,
                    appearance = settings.value,
                    onSettingChanged = { key, value ->
                        changes[key] = value
                        settings.value = when (key) {
                            "reader.theme" -> settings.value.copy(theme = value)
                            "reader.font" -> settings.value.copy(font = value)
                            "reader.fontSize" -> settings.value.copy(fontSize = value.toFloat())
                            "reader.layout" -> settings.value.copy(layout = value)
                            else -> settings.value
                        }
                    },
                    onProgress = { _, _ -> }, onClose = { closes++ }, onAsk = {},
                )
            }
        }
        compose.onNodeWithText("Page color").assertDoesNotExist()
        compose.onNodeWithText("Serif").assertDoesNotExist()
        compose.onNodeWithContentDescription("Reading appearance").performClick()
        compose.onNodeWithText("Page color").assertIsDisplayed()
        compose.onNodeWithText("Dark").performScrollTo().performClick()
        compose.onNodeWithText("Mono").performScrollTo().performClick()
        compose.onNodeWithContentDescription("Larger text").performScrollTo().performClick()
        compose.runOnIdle {
            assertEquals("dark", changes["reader.theme"])
            assertEquals("mono", changes["reader.font"])
            assertEquals("21", changes["reader.fontSize"])
        }
        pressBack()
        compose.onNodeWithText("Page color").assertDoesNotExist()
        compose.runOnIdle { assertEquals(0, closes) }
        compose.onNodeWithContentDescription("Close book").assertIsDisplayed()
        pressBack()
        compose.runOnIdle { assertEquals(1, closes) }
    }

    @Test fun contentTapHidesAndRestoresChromeWhileScrollAndSelectionStayNative() {
        var lastOffset = 0
        var asked: String? = null
        compose.setContent {
            MaterialTheme {
                TextReaderContent(
                    bookId = "scroll-fixture", title = "Test book", contents = sample,
                    onSettingChanged = { _, _ -> }, onProgress = { _, offset -> lastOffset = offset },
                    onClose = {}, onAsk = { asked = it },
                )
            }
        }
        onView(isAssignableFrom(ScrollView::class.java)).perform(click())
        awaitHidden()
        compose.onNodeWithContentDescription("Close book").assertDoesNotExist()
        compose.onNodeWithText("Show controls").performClick()
        compose.onNodeWithContentDescription("Reading appearance").assertIsDisplayed()
        onView(isAssignableFrom(ScrollView::class.java)).perform(swipeUp())
        compose.runOnIdle { assertTrue("A native scroll must advance the reading position", lastOffset > 0) }
        compose.onNodeWithContentDescription("Reading appearance").assertIsDisplayed()
        onView(withText(sample)).perform(longPressVisibleWord())
        onView(withText(sample)).check { view, missing ->
            if (missing != null) throw missing
            val textView = view as TextView
            assertTrue("A long press must retain native text selection (focused=${textView.isFocused}, selectable=${textView.isTextSelectable}, selection=${textView.selectionStart}..${textView.selectionEnd})", textView.hasSelection())
        }
        compose.onNodeWithContentDescription("Reading appearance").assertIsDisplayed()
        // Dismiss native selection before testing the independent book-level AI action.
        pressBack()
        compose.onNodeWithContentDescription("Ask AI about this book").performClick()
        compose.runOnIdle { assertEquals("", asked) }
    }

    @Test fun facingPagesKeepSwipeNavigationWhenChromeIsHidden() {
        var lastOffset = 0
        val facingOffset = mutableStateOf(0)
        compose.setContent {
            MaterialTheme {
                TextReaderContent(
                    bookId = "pages-fixture", title = "Test book", contents = sample,
                    appearance = TextReaderAppearance(layout = "facing"),
                    facingOffset = facingOffset.value,
                    onSettingChanged = { _, _ -> }, onProgress = { _, offset -> lastOffset = offset; facingOffset.value = offset },
                    onClose = {}, onAsk = {},
                )
            }
        }
        compose.onNodeWithContentDescription("Hide reading controls").performClick()
        compose.onNodeWithText("Next").assertDoesNotExist()
        // Find the native page by its text rather than touching the restore button overlay.
        onView(isRoot()).perform(swipeLeft())
        compose.runOnIdle { assertTrue("Horizontal paging must remain active with hidden controls", lastOffset > 0) }
        var hiddenOffset = 0
        compose.runOnIdle { hiddenOffset = lastOffset }
        compose.onNodeWithText("Show controls").performClick()
        compose.onNodeWithText("Next").assertIsDisplayed()
        assertVisibleTextContains(hiddenOffset)
    }

    private fun awaitHidden() {
        compose.waitUntil(timeoutMillis = 5_000) { compose.onAllNodesWithText("Show controls").fetchSemanticsNodes().isNotEmpty() }
    }

    private fun assertVisibleTextContains(offset: Int) {
        onView(isRoot()).check { root, missing ->
            if (missing != null) throw missing
            fun containsAnchor(view: View): Boolean {
                if (view is TextView) {
                    val passage = view.text.toString()
                    val start = if (passage.isNotEmpty()) sample.indexOf(passage) else -1
                    val visible = Rect()
                    if (start >= 0 && offset in start until start + passage.length && view.getGlobalVisibleRect(visible)) return true
                }
                if (view is ViewGroup) {
                    for (index in 0 until view.childCount) if (containsAnchor(view.getChildAt(index))) return true
                }
                return false
            }
            assertTrue("Showing controls must keep the previous reading passage visible", containsAnchor(root))
        }
    }

    private fun longPressVisibleWord(): ViewAction = object : ViewAction {
        override fun getDescription() = "long press a visible word in the native selectable text"

        override fun getConstraints(): Matcher<View> = allOf(isAssignableFrom(TextView::class.java), isDisplayed())

        override fun perform(uiController: UiController, view: View) {
            // Espresso/Compose idleness does not mean a platform ScrollView fling has ended.
            // Resolve the word only once native scrolling and the text's screen bounds settle.
            val deadline = SystemClock.uptimeMillis() + 5_000
            var stableSince = SystemClock.uptimeMillis()
            var previous = Rect()
            var previousScrollY = Int.MIN_VALUE
            val scroll = generateSequence(view.parent) { it.parent }.filterIsInstance<ScrollView>().firstOrNull()
            while (true) {
                val bounds = Rect()
                check(view.getGlobalVisibleRect(bounds)) { "Selectable text is not visible" }
                val scrollY = scroll?.scrollY ?: 0
                if (bounds != previous || scrollY != previousScrollY || view.isLayoutRequested) {
                    stableSince = SystemClock.uptimeMillis()
                    previous = bounds
                    previousScrollY = scrollY
                }
                if (SystemClock.uptimeMillis() - stableSince >= 300) break
                check(SystemClock.uptimeMillis() < deadline) { "Native text scrolling did not settle before selection" }
                uiController.loopMainThreadForAtLeast(50)
            }
            val coordinates = CoordinatesProvider { target ->
                val textView = target as TextView
                val layout = requireNotNull(textView.layout) { "Selectable text has no layout" }
                val visible = Rect()
                check(textView.getGlobalVisibleRect(visible)) { "Selectable text is not visible" }
                val origin = IntArray(2).also(textView::getLocationOnScreen)
                val centerY = visible.centerY() - origin[1] + textView.scrollY - textView.totalPaddingTop
                val centerLine = layout.getLineForVertical(centerY.coerceIn(0, (layout.height - 1).coerceAtLeast(0)))
                val lines = (centerLine until layout.lineCount) + (centerLine - 1 downTo 0)
                val word = Regex("\\p{L}{3,}")
                var point: FloatArray? = null
                for (line in lines) {
                    val lineStart = layout.getLineStart(line)
                    val match = word.find(textView.text.subSequence(lineStart, layout.getLineEnd(line))) ?: continue
                    val wordStart = lineStart + match.range.first
                    val wordEnd = lineStart + match.range.last + 1
                    val x = origin[0] + textView.totalPaddingLeft - textView.scrollX +
                        (layout.getPrimaryHorizontal(wordStart) + layout.getPrimaryHorizontal(wordEnd)) / 2f
                    val y = origin[1] + textView.totalPaddingTop - textView.scrollY +
                        layout.getLineBaseline(line) + layout.getLineAscent(line) / 2f
                    if (visible.contains(x.toInt(), y.toInt())) {
                        val nativeOffset = textView.getOffsetForPosition(x - origin[0], y - origin[1])
                        check(nativeOffset in wordStart until wordEnd) {
                            "Selection coordinates must hit the visible word, got offset $nativeOffset instead of $wordStart..$wordEnd"
                        }
                        point = floatArrayOf(x, y)
                        break
                    }
                }
                checkNotNull(point) { "No visible word was found for native selection" }
            }
            GeneralClickAction(Tap.LONG, coordinates, Press.FINGER).perform(uiController, view)
        }
    }
}
