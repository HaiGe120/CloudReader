package io.github.haige120.cloudreader

import android.content.Intent
import androidx.test.core.app.ActivityScenario
import androidx.test.core.app.ApplicationProvider
import androidx.test.espresso.Espresso.onView
import androidx.test.espresso.action.ViewActions.click
import androidx.test.espresso.assertion.ViewAssertions.matches
import androidx.test.espresso.matcher.ViewMatchers.isDisplayed
import androidx.test.espresso.matcher.ViewMatchers.withContentDescription
import androidx.test.espresso.matcher.ViewMatchers.withText
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.hamcrest.Matchers.not
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

/** Uses a missing ID: never imports, changes progress, or deletes the user's library. */
@RunWith(AndroidJUnit4::class)
class NativeReaderChromeTest {
    @Test fun hiddenToolbarReturnsSpaceAndRestoreRemainsReachable() {
        val intent = Intent(ApplicationProvider.getApplicationContext(), EpubReaderActivity::class.java)
        ActivityScenario.launch<EpubReaderActivity>(intent).use { scenario ->
            onView(withText("Book not found.")).check(matches(isDisplayed()))
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
}
