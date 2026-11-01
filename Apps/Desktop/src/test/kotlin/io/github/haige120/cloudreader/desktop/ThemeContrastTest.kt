package io.github.haige120.cloudreader.desktop

import androidx.compose.material3.ColorScheme
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.luminance
import io.github.haige120.cloudreader.ui.cloudReaderColorScheme
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.max
import kotlin.math.min

/** Pure palette checks: no windows, local library, preferences or provider accounts. */
class ThemeContrastTest {
    @Test
    fun lightThemeTextPairsMeetMinimumContrast() {
        assertReadablePairs("light", cloudReaderColorScheme(darkTheme = false))
    }

    @Test
    fun darkThemeTextPairsMeetMinimumContrast() {
        assertReadablePairs("dark", cloudReaderColorScheme(darkTheme = true))
    }

    private fun assertReadablePairs(theme: String, colors: ColorScheme) {
        // The card's selected background is secondaryContainer, and BOTH its title
        // and subtitle use onSecondaryContainer. Android separately checks the
        // actual card/text pixels against these same roles.
        val pairs = listOf(
            TextPair("onSurface/surface (unselected destination title and subtitle)", colors.onSurface, colors.surface),
            TextPair("onBackground/background", colors.onBackground, colors.background),
            TextPair("onSurfaceVariant/surfaceVariant (connection summary)", colors.onSurfaceVariant, colors.surfaceVariant),
            TextPair("primary/surface (unselected Connect)", colors.primary, colors.surface),
            TextPair("primary/secondaryContainer (selected Connect)", colors.primary, colors.secondaryContainer),
            TextPair("onPrimary/primary", colors.onPrimary, colors.primary),
            TextPair("onPrimaryContainer/primaryContainer", colors.onPrimaryContainer, colors.primaryContainer),
            TextPair("secondary/surface", colors.secondary, colors.surface),
            TextPair("onSecondary/secondary", colors.onSecondary, colors.secondary),
            TextPair("onSecondaryContainer/secondaryContainer (selected destination title and subtitle)", colors.onSecondaryContainer, colors.secondaryContainer),
            TextPair("onTertiary/tertiary", colors.onTertiary, colors.tertiary),
            TextPair("onTertiaryContainer/tertiaryContainer", colors.onTertiaryContainer, colors.tertiaryContainer),
            TextPair("error/surface", colors.error, colors.surface),
            TextPair("onError/error", colors.onError, colors.error),
            TextPair("onErrorContainer/errorContainer (attention summary, help and details)", colors.onErrorContainer, colors.errorContainer),
            TextPair("inverseOnSurface/inverseSurface", colors.inverseOnSurface, colors.inverseSurface),
            TextPair("inversePrimary/inverseSurface", colors.inversePrimary, colors.inverseSurface),
        )
        val failures = mutableListOf<String>()
        pairs.forEach { (role, foreground, background) ->
            assertEquals("$theme $role foreground must be opaque", 1f, foreground.alpha, 0.0001f)
            assertEquals("$theme $role background must be opaque", 1f, background.alpha, 0.0001f)
            val lighter = max(foreground.luminance().toDouble(), background.luminance().toDouble())
            val darker = min(foreground.luminance().toDouble(), background.luminance().toDouble())
            val ratio = (lighter + 0.05) / (darker + 0.05)
            if (!ratio.isFinite() || ratio < MINIMUM_CONTRAST) {
                failures += "$role: $ratio:1"
            }
        }
        assertTrue(
            "$theme text pairs require at least $MINIMUM_CONTRAST:1 contrast:\n${failures.joinToString("\n")}",
            failures.isEmpty(),
        )
    }

    private data class TextPair(val role: String, val foreground: Color, val background: Color)

    private companion object {
        const val MINIMUM_CONTRAST = 4.5
    }
}
