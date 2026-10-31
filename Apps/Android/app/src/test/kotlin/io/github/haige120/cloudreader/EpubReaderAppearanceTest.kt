package io.github.haige120.cloudreader

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.readium.r2.navigator.preferences.ColumnCount
import org.readium.r2.navigator.preferences.FontFamily
import org.readium.r2.navigator.preferences.Spread
import org.readium.r2.shared.ExperimentalReadiumApi

@OptIn(ExperimentalReadiumApi::class)
class EpubReaderAppearanceTest {
    @Test fun absentSettingsKeepExistingEpubPaginationAndSharedReaderDefaults() {
        assertEquals(EpubReaderAppearance(), EpubReaderAppearance.fromSettings(emptyMap()))
        assertEquals("single", EpubReaderAppearance.fromSettings(mapOf("reader.layout" to "scroll")).layout)
    }

    @Test fun readsSharedTypographyAndColorsWithEpubSpecificLayout() {
        val appearance = EpubReaderAppearance.fromSettings(mapOf(
            "reader.theme" to "custom", "reader.font" to "mono", "reader.fontSize" to "27.0",
            "reader.customBackground" to "E6E8D8", "reader.customForeground" to "#1D3A2A",
            "reader.layout" to "scroll", "reader.epub.layout" to "facing",
        ))
        assertEquals(EpubReaderAppearance("custom", "mono", 27, "facing", "E6E8D8", "#1D3A2A"), appearance)
    }

    @Test fun invalidOptionsFallBackWithoutTakingOtherReadersLayout() {
        val appearance = EpubReaderAppearance.fromSettings(mapOf(
            "reader.theme" to "pink", "reader.font" to "missing", "reader.fontSize" to "no-size",
            "reader.epub.layout" to "unknown", "reader.layout" to "facing",
        ))
        assertEquals(EpubReaderAppearance(), appearance)
    }

    @Test fun fontSizeIsClampedAndNonFiniteValuesAreRejected() {
        fun fontSize(value: String) = EpubReaderAppearance.fromSettings(mapOf("reader.fontSize" to value)).fontSize
        assertEquals(14, fontSize("-100"))
        assertEquals(38, fontSize("1000"))
        assertEquals(20, fontSize("20.9"))
        assertEquals(20, fontSize("NaN"))
        assertEquals(20, fontSize("Infinity"))
        assertEquals(20, fontSize("-Infinity"))
    }

    @Test fun updatedSettingRetainsOtherPreferencesAndNormalizesValue() {
        val original = EpubReaderAppearance("sepia", "sans", 22, "facing", "#E6E8D8", "#1D3A2A")
        assertEquals(original.copy(fontSize = 38), original.updated("reader.fontSize", "99"))
        assertEquals(original.copy(layout = "scroll"), original.updated("reader.epub.layout", "scroll"))
        assertEquals(original, original.updated("reader.layout", "scroll"))
    }

    @Test fun scrollingUsesOneColumnAndDisablesFixedLayoutSpreads() {
        val mapped = EpubReaderAppearance(layout = "scroll").readiumLayout(wideScreen = true)
        assertTrue(mapped.scroll)
        assertEquals(ColumnCount.ONE, mapped.columnCount)
        assertEquals(Spread.NEVER, mapped.spread)
    }

    @Test fun onePageExplicitlyDisablesScrollingAndSpreads() {
        val mapped = EpubReaderAppearance(layout = "single").readiumLayout(wideScreen = true)
        assertFalse(mapped.scroll)
        assertEquals(ColumnCount.ONE, mapped.columnCount)
        assertEquals(Spread.NEVER, mapped.spread)
    }

    @Test fun twoPagesUseTwoColumnsAndFixedLayoutSpreadsOnWideScreen() {
        val mapped = EpubReaderAppearance(layout = "facing").readiumLayout(wideScreen = true)
        assertFalse(mapped.scroll)
        assertEquals(ColumnCount.TWO, mapped.columnCount)
        assertEquals(Spread.ALWAYS, mapped.spread)
    }

    @Test fun twoPageChoiceFallsBackOnCompactScreenWithoutLosingSavedChoice() {
        val appearance = EpubReaderAppearance(layout = "facing")
        val compact = appearance.readiumLayout(wideScreen = false)
        assertFalse(compact.scroll)
        assertEquals(ColumnCount.ONE, compact.columnCount)
        assertEquals(Spread.NEVER, compact.spread)
        assertEquals("facing", appearance.layout)
        assertEquals(ColumnCount.TWO, appearance.readiumLayout(wideScreen = true).columnCount)
    }

    @Test fun fontFamiliesMapToCssGenericFamiliesAndFontSizeToBaseMultiplier() {
        assertEquals(FontFamily.SERIF, EpubReaderAppearance(font = "serif").readiumFontFamily)
        assertEquals(FontFamily.SANS_SERIF, EpubReaderAppearance(font = "sans").readiumFontFamily)
        assertEquals(FontFamily.MONOSPACE, EpubReaderAppearance(font = "mono").readiumFontFamily)
        assertEquals(1.25, EpubReaderAppearance(fontSize = 20).readiumFontSize, 0.0)
        assertEquals(0.875, EpubReaderAppearance(fontSize = 1).readiumFontSize, 0.0)
        assertEquals(2.375, EpubReaderAppearance(fontSize = 80).readiumFontSize, 0.0)
    }

    @Test fun systemThemeFollowsNightModeAndExplicitThemeDoesNot() {
        assertEquals("light", EpubReaderAppearance().palette(systemDark = false).theme)
        assertEquals("dark", EpubReaderAppearance().palette(systemDark = true).theme)
        assertEquals("light", EpubReaderAppearance(theme = "light").palette(systemDark = true).theme)
        assertEquals("sepia", EpubReaderAppearance(theme = "sepia").palette(systemDark = true).theme)
    }

    @Test fun standardThemesUseExistingTextReaderPalette() {
        assertEquals(0xFF232322.toInt(), EpubReaderAppearance(theme = "dark").palette().background)
        assertEquals(0xFFE5E1D8.toInt(), EpubReaderAppearance(theme = "dark").palette().foreground)
        assertEquals(0xFFECE1CB.toInt(), EpubReaderAppearance(theme = "sepia").palette().background)
        assertEquals(0xFFFFFDF8.toInt(), EpubReaderAppearance(theme = "light").palette().background)
    }

    @Test fun customColorsAcceptSharedRgbHexAndHaveReadableFallbacks() {
        val palette = EpubReaderAppearance(theme = "custom", customBackground = " e6e8d8 ", customForeground = "#1D3A2A").palette()
        assertEquals(0xFFE6E8D8.toInt(), palette.background)
        assertEquals(0xFF1D3A2A.toInt(), palette.foreground)
        assertEquals(0xB31D3A2A.toInt(), palette.muted)
        val invalid = EpubReaderAppearance(theme = "custom", customBackground = "not-a-color", customForeground = "#80FFFFFF").palette()
        assertEquals(0xFFF8F4EB.toInt(), invalid.background)
        assertEquals(0xFF292621.toInt(), invalid.foreground)
    }

    @Test fun observedKeysIncludeSharedAppearanceAndOnlyEpubPagination() {
        assertEquals(setOf(
            "reader.theme", "reader.font", "reader.fontSize", "reader.epub.layout",
            "reader.customBackground", "reader.customForeground",
        ), EpubReaderAppearance.SETTING_KEYS.toSet())
        assertFalse(EpubReaderAppearance.SETTING_KEYS.contains("reader.layout"))
    }
}
