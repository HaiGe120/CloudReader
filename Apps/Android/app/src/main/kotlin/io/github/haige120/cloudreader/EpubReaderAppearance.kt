package io.github.haige120.cloudreader

import org.readium.r2.navigator.epub.EpubPreferences
import org.readium.r2.navigator.preferences.Color
import org.readium.r2.navigator.preferences.ColumnCount
import org.readium.r2.navigator.preferences.FontFamily
import org.readium.r2.navigator.preferences.Spread
import org.readium.r2.navigator.preferences.Theme
import org.readium.r2.shared.ExperimentalReadiumApi

/** EPUB uses the shared typography/color preferences and its own pagination preference. */
internal data class EpubReaderAppearance(
    val theme: String = "system",
    val font: String = "serif",
    val fontSize: Int = 20,
    val layout: String = "single",
    val customBackground: String = "#F8F4EB",
    val customForeground: String = "#292621",
) {
    companion object {
        const val LAYOUT_KEY = "reader.epub.layout"
        val SETTING_KEYS = listOf(
            "reader.theme", "reader.font", "reader.fontSize", LAYOUT_KEY,
            "reader.customBackground", "reader.customForeground",
        )

        fun fromSettings(settings: Map<String, String>): EpubReaderAppearance = EpubReaderAppearance(
            theme = settings["reader.theme"].takeIf { it in THEMES } ?: "system",
            font = settings["reader.font"].takeIf { it in FONTS } ?: "serif",
            fontSize = settings["reader.fontSize"]?.toDoubleOrNull()?.takeIf { it.isFinite() }
                ?.coerceIn(14.0, 38.0)?.toInt() ?: 20,
            layout = settings[LAYOUT_KEY].takeIf { it in LAYOUTS } ?: "single",
            customBackground = settings["reader.customBackground"] ?: "#F8F4EB",
            customForeground = settings["reader.customForeground"] ?: "#292621",
        )

        private val THEMES = setOf("system", "light", "sepia", "dark", "custom")
        private val FONTS = setOf("serif", "sans", "mono")
        private val LAYOUTS = setOf("scroll", "single", "facing")
    }

    internal fun updated(key: String, value: String): EpubReaderAppearance = fromSettings(
        mapOf(
            "reader.theme" to theme,
            "reader.font" to font,
            "reader.fontSize" to fontSize.toString(),
            LAYOUT_KEY to layout,
            "reader.customBackground" to customBackground,
            "reader.customForeground" to customForeground,
        ) + (key to value)
    )

    internal fun palette(systemDark: Boolean = false): EpubReaderPalette = resolvedPalette(systemDark)

    /** Readium's font size is a multiplier of its 16px base, not a point size. */
    internal val readiumFontSize: Double get() = fontSize.coerceIn(14, 38) / 16.0

    internal val readiumFontFamily: FontFamily get() = when (font) {
        "sans" -> FontFamily.SANS_SERIF
        "mono" -> FontFamily.MONOSPACE
        else -> FontFamily.SERIF
    }

    @OptIn(ExperimentalReadiumApi::class)
    internal fun readiumLayout(wideScreen: Boolean): EpubReadiumLayout {
        val twoPages = layout == "facing" && wideScreen
        return EpubReadiumLayout(
            scroll = layout == "scroll",
            columnCount = if (twoPages) ColumnCount.TWO else ColumnCount.ONE,
            spread = if (twoPages) Spread.ALWAYS else Spread.NEVER,
        )
    }

    internal fun resolvedPalette(systemDark: Boolean): EpubReaderPalette = when {
        theme == "dark" || (theme == "system" && systemDark) ->
            EpubReaderPalette("dark", 0xFF232322.toInt(), 0xFFE5E1D8.toInt())
        theme == "sepia" -> EpubReaderPalette("sepia", 0xFFECE1CB.toInt(), 0xFF292621.toInt())
        theme == "custom" -> EpubReaderPalette(
            "custom", parseReaderHexColor(customBackground, 0xFFF8F4EB.toInt()),
            parseReaderHexColor(customForeground, 0xFF292621.toInt()),
        )
        theme == "light" -> EpubReaderPalette("light", 0xFFFFFDF8.toInt(), 0xFF292621.toInt())
        else -> EpubReaderPalette("light", 0xFFF8F4EB.toInt(), 0xFF292621.toInt())
    }

    @OptIn(ExperimentalReadiumApi::class)
    fun toReadiumPreferences(systemDark: Boolean = false, wideScreen: Boolean = true): EpubPreferences {
        val palette = resolvedPalette(systemDark)
        val pages = readiumLayout(wideScreen)
        return EpubPreferences(
            scroll = pages.scroll,
            columnCount = pages.columnCount,
            spread = pages.spread,
            fontFamily = readiumFontFamily,
            fontSize = readiumFontSize,
            // Readium requires this to be false for typography to override publisher styles.
            publisherStyles = false,
            backgroundColor = Color(palette.background),
            textColor = Color(palette.foreground),
            theme = when (palette.theme) {
                "dark" -> Theme.DARK
                "sepia" -> Theme.SEPIA
                else -> Theme.LIGHT
            },
        )
    }
}

@OptIn(ExperimentalReadiumApi::class)
internal data class EpubReadiumLayout(val scroll: Boolean, val columnCount: ColumnCount, val spread: Spread)

internal data class EpubReaderPalette(
    val theme: String,
    val background: Int,
    val foreground: Int,
    val muted: Int = (foreground and 0x00FFFFFF) or 0xB3000000.toInt(),
)

/** Shared reader colors accept RGB hex with or without the leading #. */
internal fun parseReaderHexColor(value: String, fallback: Int): Int {
    val hex = value.trim().removePrefix("#")
    if (hex.length != 6 || hex.any { it !in '0'..'9' && it !in 'a'..'f' && it !in 'A'..'F' }) return fallback
    return (0xFF000000L or (hex.toLongOrNull(16) ?: return fallback)).toInt()
}
