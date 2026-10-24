package io.github.haige120.cloudreader

import android.content.Intent
import android.view.View
import android.widget.TextView
import androidx.test.core.app.ActivityScenario
import androidx.test.core.app.ApplicationProvider
import androidx.test.espresso.Espresso.onView
import androidx.test.espresso.action.ViewActions.click
import androidx.test.espresso.assertion.ViewAssertions.matches
import androidx.test.espresso.assertion.ViewAssertions.doesNotExist
import androidx.test.espresso.matcher.ViewMatchers.isDisplayed
import androidx.test.espresso.matcher.ViewMatchers.withContentDescription
import androidx.test.espresso.matcher.ViewMatchers.withText
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.hamcrest.Matchers.not
import org.junit.Assert.assertTrue
import org.junit.Assert.assertEquals
import org.junit.Test
import org.junit.runner.RunWith

/** Uses a missing ID: never imports, changes progress, or deletes the user's library. */
@RunWith(AndroidJUnit4::class)
class NativeReaderChromeTest {
    @Test fun hiddenToolbarReturnsSpaceAndRestoreRemainsReachable() {
        val intent = Intent(ApplicationProvider.getApplicationContext(), EpubReaderActivity::class.java)
        ActivityScenario.launch<EpubReaderActivity>(intent).use { scenario ->
            onView(withText("Book not found.")).check(matches(isDisplayed()))
            scenario.onActivity { activity ->
                // Explicit PDF defaults: EPUB can use a fully hidden shell independently.
                activity.setContentView(NativeReaderChrome(activity, R.id.epub_viewer_container).root)
            }
            var expandedTop = 0
            scenario.onActivity { activity ->
                expandedTop = activity.findViewById<android.view.View>(R.id.epub_viewer_container).top
            }
            onView(withContentDescription("Hide reading controls")).perform(click())
            onView(withContentDescription("Back to library")).check(matches(not(isDisplayed())))
            onView(withContentDescription("Show reading controls")).check(matches(isDisplayed()))
            scenario.onActivity { activity ->
                assertTrue(activity.findViewById<android.view.View>(R.id.epub_viewer_container).top < expandedTop)
            }
            onView(withContentDescription("Show reading controls")).perform(click())
            onView(withContentDescription("Back to library")).check(matches(isDisplayed()))
            onView(withContentDescription("Hide reading controls")).check(matches(isDisplayed()))
        }
    }

    @Test fun fullyHiddenChromeHasNoOverlayAndRecoversThroughAccessibility() {
        val intent = Intent(ApplicationProvider.getApplicationContext(), EpubReaderActivity::class.java)
        ActivityScenario.launch<EpubReaderActivity>(intent).use { scenario ->
            onView(withText("Book not found.")).check(matches(isDisplayed()))
            lateinit var chrome: NativeReaderChrome
            var appearanceClicks = 0
            val ink = 0xFFF1EDE2.toInt()
            scenario.onActivity { activity ->
                chrome = NativeReaderChrome(activity, R.id.epub_viewer_container, showRestoreControl = false, immersiveSystemBars = true)
                chrome.setTitle("Appearance fixture")
                chrome.setAppearanceAction { appearanceClicks++ }
                chrome.setReadingColors(0xFF202120.toInt(), ink, 0xFFB8B6AF.toInt())
                activity.setContentView(chrome.root)
            }
            onView(withContentDescription("Reading appearance")).perform(click())
            scenario.onActivity {
                assertEquals(1, appearanceClicks)
                performRootAction(chrome.root, "Hide reading controls")
            }
            onView(withContentDescription("Back to library")).check(matches(not(isDisplayed())))
            onView(withContentDescription("Reading appearance")).check(matches(not(isDisplayed())))
            onView(withText("Show controls")).check(doesNotExist())
            onView(withContentDescription("Show reading controls")).check(doesNotExist())
            scenario.onActivity {
                val actions = chrome.root.createAccessibilityNodeInfo().actionList.map { it.label?.toString() }
                assertTrue("Hidden controls must expose accessible recovery", "Show reading controls" in actions)
                assertTrue("The old action must be removed when controls hide", "Hide reading controls" !in actions)
                performRootAction(chrome.root, "Show reading controls")
            }
            onView(withContentDescription("Reading appearance")).check(matches(isDisplayed())).perform(click())
            onView(withText("Appearance fixture")).check { view, missing ->
                if (missing != null) throw missing
                assertEquals(ink, (view as TextView).currentTextColor)
            }
            scenario.onActivity { assertEquals(2, appearanceClicks) }
        }
    }

    private fun performRootAction(root: View, label: String) {
        val action = root.createAccessibilityNodeInfo().actionList.firstOrNull { it.label?.toString() == label }
        assertTrue("Reader root must offer $label", action != null)
        assertTrue("Reader root action must be handled", root.performAccessibilityAction(requireNotNull(action).id, null))
    }
}
