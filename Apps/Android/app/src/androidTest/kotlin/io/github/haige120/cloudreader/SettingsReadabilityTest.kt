package io.github.haige120.cloudreader

import android.graphics.Bitmap
import android.os.SystemClock
import android.util.Log
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.graphics.luminance
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.graphics.toPixelMap
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.test.ComposeTimeoutException
import androidx.compose.ui.test.SemanticsMatcher
import androidx.compose.ui.test.SemanticsNodeInteraction
import androidx.compose.ui.test.assert
import androidx.compose.ui.test.assertHasClickAction
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsEnabled
import androidx.compose.ui.test.assertIsOff
import androidx.compose.ui.test.assertIsOn
import androidx.compose.ui.test.assertWidthIsEqualTo
import androidx.compose.ui.test.captureToImage
import androidx.compose.ui.test.isToggleable
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.compose.ui.test.performSemanticsAction
import androidx.compose.ui.text.TextLayoutResult
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.dp
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import io.github.haige120.cloudreader.ui.CloudReaderTheme
import io.github.haige120.cloudreader.ui.ConnectionStatus
import io.github.haige120.cloudreader.ui.SyncDestinationCard
import io.github.haige120.cloudreader.ui.cloudReaderColorScheme
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import java.nio.file.Files
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min

/**
 * Only synthetic copy, remembered UI state and cache screenshots are used here.
 * createComposeRule hosts ComponentActivity, never MainActivity or a view model.
 * Run only on a disposable emulator: CloudReaderApp.onCreate still starts before
 * these tests and initializes the target application's default library/preferences.
 */
@RunWith(AndroidJUnit4::class)
class SettingsReadabilityTest {
    @get:Rule
    val compose = createComposeRule()

    private lateinit var screenshotDirectory: File
    private var captureSequence = 0

    @Test
    fun lightThemeAt320dpKeepsSettingsReadableAndOperable() =
        verifySettings(darkTheme = false, widthDp = 320)

    @Test
    fun lightThemeAt360dpKeepsSettingsReadableAndOperable() =
        verifySettings(darkTheme = false, widthDp = 360)

    @Test
    fun darkThemeAt320dpKeepsSettingsReadableAndOperable() =
        verifySettings(darkTheme = true, widthDp = 320)

    @Test
    fun darkThemeAt360dpKeepsSettingsReadableAndOperable() =
        verifySettings(darkTheme = true, widthDp = 360)

    private fun verifySettings(darkTheme: Boolean, widthDp: Int) {
        val selections = mutableListOf<Boolean>()
        var connectClicks = 0
        var helpClicks = 0
        compose.setContent {
            val deviceDensity = LocalDensity.current.density
            CompositionLocalProvider(LocalDensity provides Density(deviceDensity, FONT_SCALE)) {
                CloudReaderTheme(darkTheme = darkTheme) {
                    var selected by remember { mutableStateOf(true) }
                    Column(
                        Modifier.width(widthDp.dp).fillMaxHeight()
                            .background(MaterialTheme.colorScheme.background)
                            .testTag(FIXTURE)
                            .verticalScroll(rememberScrollState())
                            .padding(16.dp),
                        verticalArrangement = Arrangement.spacedBy(12.dp),
                    ) {
                        SyncDestinationCard(
                            title = TITLE,
                            subtitle = SUBTITLE,
                            selected = selected,
                            enabled = true,
                            onSelected = { selected = it; selections += it },
                            actions = {
                                TextButton(onClick = { connectClicks++ }) { Text("Connect") }
                            },
                        )
                        ConnectionStatus(
                            message = "$SUMMARY\n$DETAILS",
                            needsAttention = true,
                            onSetup = { helpClicks++ },
                        )
                        ConnectionStatus(message = READY_SUMMARY, needsAttention = false)
                    }
                }
            }
        }

        // Save the untouched, collapsed first render before any scroll or click.
        persistFirstRender(darkTheme, widthDp)
        compose.onNodeWithTag(FIXTURE).assertWidthIsEqualTo(widthDp.dp)
        compose.onNodeWithText(DETAILS, useUnmergedTree = true).assertDoesNotExist()

        val colors = cloudReaderColorScheme(darkTheme)
        assertReadableText(TITLE, colors.onSecondaryContainer, colors.secondaryContainer)
        assertReadableText(SUBTITLE, colors.onSecondaryContainer, colors.secondaryContainer)
        assertReadableText("Connect", colors.primary, colors.secondaryContainer)

        val checkbox = compose.onNode(isToggleable())
        compose.onNodeWithText("Connect").performScrollTo().assertIsDisplayed()
            .assertIsEnabled().assertHasClickAction().performClick()
        checkbox.assertIsOn()
        compose.runOnIdle {
            assertEquals(1, connectClicks)
            assertTrue("Connect must not toggle destination selection", selections.isEmpty())
        }
        checkbox.performScrollTo().assertIsDisplayed().assertIsEnabled().assertHasClickAction()
            .assert(SemanticsMatcher.expectValue(SemanticsProperties.Role, Role.Checkbox))
            .assertIsOn().performClick().assertIsOff()
        compose.runOnIdle { assertEquals(listOf(false), selections) }
        // These pixels must change to the unselected surface/onSurface pairing.
        assertReadableText(TITLE, colors.onSurface, colors.surface)
        assertReadableText(SUBTITLE, colors.onSurface, colors.surface)
        assertReadableText("Connect", colors.primary, colors.surface)
        compose.onNodeWithText("Connect").performScrollTo().assertIsDisplayed()
            .assertIsEnabled().assertHasClickAction().performClick()
        compose.runOnIdle { assertEquals(2, connectClicks) }
        checkbox.assertIsOff()

        checkbox.performScrollTo().performClick().assertIsOn()
        compose.runOnIdle { assertEquals(listOf(false, true), selections) }
        assertReadableText(TITLE, colors.onSecondaryContainer, colors.secondaryContainer)
        assertReadableText(SUBTITLE, colors.onSecondaryContainer, colors.secondaryContainer)

        assertReadableText(SUMMARY, colors.onErrorContainer, colors.errorContainer)
        assertReadableText("Google connection help", colors.onErrorContainer, colors.errorContainer)
        compose.onNodeWithText("Google connection help").performScrollTo().assertIsDisplayed()
            .assertIsEnabled().assertHasClickAction().performClick()
        compose.runOnIdle { assertEquals(1, helpClicks) }
        compose.onNodeWithText(DETAILS, useUnmergedTree = true).assertDoesNotExist()

        assertReadableText("Show technical details", colors.onErrorContainer, colors.errorContainer)
        compose.onNodeWithText("Show technical details").performScrollTo().assertIsDisplayed()
            .assertIsEnabled().assertHasClickAction().performClick()
        assertReadableText(DETAILS, colors.onErrorContainer, colors.errorContainer)
        compose.onNodeWithText("Hide technical details").performScrollTo().assertIsDisplayed()
            .assertIsEnabled().assertHasClickAction().performClick()
        compose.onNodeWithText(DETAILS, useUnmergedTree = true).assertDoesNotExist()
        compose.onNodeWithText("Show technical details").assertIsDisplayed()
        assertReadableText(READY_SUMMARY, colors.onSurfaceVariant, colors.surfaceVariant)
        compose.runOnIdle {
            assertEquals(listOf(false, true), selections)
            assertEquals(2, connectClicks)
            assertEquals(1, helpClicks)
        }
    }

    private fun assertReadableText(text: String, foreground: Color, background: Color) {
        val node = compose.onNodeWithText(text, useUnmergedTree = true)
        node.performScrollTo().assertIsDisplayed()
        val layouts = mutableListOf<TextLayoutResult>()
        node.performSemanticsAction(SemanticsActions.GetTextLayoutResult) { getLayout ->
            assertTrue("Text must expose its layout: $text", getLayout(layouts))
        }
        assertEquals("One text layout expected for $text", 1, layouts.size)
        val layout = layouts.single()
        assertEquals(FONT_SCALE, layout.layoutInput.density.fontScale, 0.001f)
        assertFalse("Text must wrap without vertical overflow: $text", layout.didOverflowHeight)
        repeat(layout.lineCount) { line ->
            assertFalse("Text must not be ellipsized: $text", layout.isLineEllipsized(line))
            // Compose can retain a wider paragraph container after shrinking a
            // short Text to its intrinsic width (e.g. 703px paragraph / 374px
            // Text). Check actual line extents, not that container's width flag.
            assertTrue("Line must not clip on the left: $text", layout.getLineLeft(line) >= -1f)
            assertTrue("Line must not clip on the right: $text", layout.getLineRight(line) <= layout.size.width + 1f)
        }
        val bounds = node.fetchSemanticsNode().boundsInRoot
        val viewport = compose.onNodeWithTag(FIXTURE).fetchSemanticsNode().boundsInRoot
        // boundsInRoot is clipped by ancestors; compare with the layout's full
        // pixel size so a partially visible Text cannot pass as fully displayed.
        assertEquals("Text must not be horizontally clipped: $text", layout.size.width.toFloat(), bounds.width, 1f)
        assertEquals("Text must not be vertically clipped: $text", layout.size.height.toFloat(), bounds.height, 1f)
        assertTrue(
            "The complete text must fit in the viewport: $text ($bounds in $viewport)",
            bounds.left >= viewport.left - 1f && bounds.right <= viewport.right + 1f &&
                bounds.top >= viewport.top - 1f && bounds.bottom <= viewport.bottom + 1f,
        )

        // Sample the rendered glyphs AND the surface behind each Text. Palette-only
        // tests would miss a hardcoded Text color or a mismatched selected surface.
        val sample = awaitRenderedTextPair(node, text, foreground, background)
        assertTrue("Rendered glyph color must match its role for '$text'", sample.foregroundPixels >= 8)
        assertTrue(
            "Rendered background must match its role for '$text'",
            sample.backgroundPixels >= sample.minimumBackgroundPixels,
        )
        // Antialiased edge pixels are intentionally excluded; use the closest
        // opaque glyph/surface pixels, with at least eight glyph pixels required.
        val actualForeground = sample.closestForeground
        val actualBackground = sample.closestBackground
        val lighter = max(actualForeground.luminance(), actualBackground.luminance())
        val darker = min(actualForeground.luminance(), actualBackground.luminance())
        val ratio = (lighter + 0.05f) / (darker + 0.05f)
        assertTrue("Rendered text contrast for '$text' was $ratio; expected >= 4.5", ratio >= 4.5f)
    }

    private fun awaitRenderedTextPair(
        node: SemanticsNodeInteraction,
        text: String,
        foreground: Color,
        background: Color,
    ): TextPixels {
        var sample = sampleTextPixels(node.captureToImage(), foreground, background)
        if (sample.matchesRoles) return sample
        val first = sample
        val startedAt = SystemClock.elapsedRealtime()
        val name = "pair-${++captureSequence}-${text.take(30).replace(Regex("[^A-Za-z0-9]+"), "-")}"
        try {
            // API 31 uses a native RippleDrawable: its render-thread fade follows
            // real time, independently of Compose's test clock / idling resource.
            // Yield to actual frames until the original pixel thresholds pass.
            // A persistent wrong foreground/background still fails after 5 seconds.
            compose.waitUntil(timeoutMillis = 5_000) {
                sample = sampleTextPixels(node.captureToImage(), foreground, background)
                sample.matchesRoles
            }
        } catch (timeout: ComposeTimeoutException) {
            saveImage(first.image, "$name-first.png")
            saveImage(sample.image, "$name-timeout.png")
            saveImage(compose.onNodeWithTag(FIXTURE).captureToImage(), "$name-viewport.png")
            logPixels("$name timeout", sample.image)
            throw AssertionError(
                "Rendered role pair did not settle for '$text': " +
                    "foreground ${sample.foregroundPixels}/8, " +
                    "background ${sample.backgroundPixels}/${sample.minimumBackgroundPixels}; " +
                    "expected fg=${foreground.toArgb().toUInt().toString(16)} " +
                    "bg=${background.toArgb().toUInt().toString(16)}",
                timeout,
            )
        }
        // Retain evidence of the native transient and the accepted frame. Sampling
        // both colors in that SAME frame keeps the actual text/surface pairing.
        saveImage(first.image, "$name-first.png")
        saveImage(sample.image, "$name-settled.png")
        Log.i("SettingsReadabilityTest", "$name settled in ${SystemClock.elapsedRealtime() - startedAt}ms")
        logPixels("$name first", first.image)
        logPixels("$name settled", sample.image)
        return sample
    }

    private fun sampleTextPixels(image: ImageBitmap, foreground: Color, background: Color): TextPixels {
        val pixels = image.toPixelMap()
        var foregroundPixels = 0
        var backgroundPixels = 0
        var closestForeground: Color? = null
        var closestBackground: Color? = null
        var foregroundDistance = Float.POSITIVE_INFINITY
        var backgroundDistance = Float.POSITIVE_INFINITY
        for (y in 0 until pixels.height) {
            for (x in 0 until pixels.width) {
                val pixel = pixels[x, y]
                val fgDistance = colorDistance(pixel, foreground)
                val bgDistance = colorDistance(pixel, background)
                if (fgDistance <= PIXEL_TOLERANCE) foregroundPixels++
                if (bgDistance <= PIXEL_TOLERANCE) backgroundPixels++
                if (fgDistance < foregroundDistance) {
                    foregroundDistance = fgDistance
                    closestForeground = pixel
                }
                if (bgDistance < backgroundDistance) {
                    backgroundDistance = bgDistance
                    closestBackground = pixel
                }
            }
        }
        return TextPixels(
            image, foregroundPixels, backgroundPixels,
            checkNotNull(closestForeground), checkNotNull(closestBackground),
        )
    }

    private fun persistFirstRender(darkTheme: Boolean, widthDp: Int) {
        val image: ImageBitmap = compose.onNodeWithTag(FIXTURE).captureToImage()
        val cache = InstrumentationRegistry.getInstrumentation().targetContext.cacheDir
        val root = File(cache, "auth-readability")
        check(root.isDirectory || root.mkdirs()) { "Cannot create screenshot directory $root" }
        val theme = if (darkTheme) "dark" else "light"
        // Unique per invocation: never replace another test's evidence or clear cache.
        val directory = Files.createTempDirectory(root.toPath(), "settings-${widthDp}dp-").toFile()
        screenshotDirectory = directory
        val screenshot = File(directory, "settings-$theme.png")
        screenshot.outputStream().use { output ->
            check(image.asAndroidBitmap().compress(Bitmap.CompressFormat.PNG, 100, output)) {
                "Could not save first-render screenshot $screenshot"
            }
        }
        assertTrue("Screenshot must be retained in target cache", screenshot.length() > 0)
        Log.i("SettingsReadabilityTest", "First render: ${screenshot.absolutePath}")
    }

    private fun saveImage(image: ImageBitmap, name: String) {
        File(screenshotDirectory, name).outputStream().use {
            check(image.asAndroidBitmap().compress(Bitmap.CompressFormat.PNG, 100, it))
        }
    }

    private fun logPixels(stage: String, image: ImageBitmap) {
        val colors = mutableMapOf<Int, Int>()
        val pixels = image.toPixelMap()
        for (y in 0 until pixels.height) for (x in 0 until pixels.width) {
            val color = pixels[x, y].toArgb()
            colors[color] = (colors[color] ?: 0) + 1
        }
        val dominant = colors.entries.sortedByDescending { it.value }.take(8)
            .joinToString { "${it.key.toUInt().toString(16)}=${it.value}" }
        Log.i("SettingsReadabilityTest", "PIXELS $stage $dominant")
    }

    private data class TextPixels(
        val image: ImageBitmap,
        val foregroundPixels: Int,
        val backgroundPixels: Int,
        val closestForeground: Color,
        val closestBackground: Color,
    ) {
        val minimumBackgroundPixels: Int get() = max(1, image.width * image.height / 5)
        val matchesRoles: Boolean get() = foregroundPixels >= 8 && backgroundPixels >= minimumBackgroundPixels
    }

    private fun colorDistance(first: Color, second: Color): Float = max(
        max(abs(first.red - second.red), abs(first.green - second.green)),
        max(abs(first.blue - second.blue), abs(first.alpha - second.alpha)),
    )

    private companion object {
        const val FIXTURE = "settings-readability-fixture"
        const val FONT_SCALE = 1.5f
        const val PIXEL_TOLERANCE = 2f / 255f
        const val TITLE = "Google Drive"
        const val SUBTITLE = "Ready to sync fixture books."
        const val SUMMARY = "Google connection needs setup."
        const val DETAILS = "Fixture diagnostic: no account or credentials.\nNo network request was made."
        const val READY_SUMMARY = "Fixture destination is ready."
    }
}
