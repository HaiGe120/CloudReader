package io.github.haige120.cloudreader.core.application

import io.github.haige120.cloudreader.core.model.BookRecord

enum class AppDestination(val label: String) { LIBRARY("Library"), ASSISTANT("Ask AI"), SETTINGS("Settings") }

/** The same ordering/filter rules are used by all three application hosts. */
data class LibraryPresentation(
    val books: List<BookRecord>,
    val query: String = "",
    val favoritesOnly: Boolean = false,
) {
    val ordered = books.sortedWith(compareByDescending<BookRecord> { it.lastOpenedAt != null }
        .thenByDescending { it.lastOpenedAt ?: it.addedAt }.thenBy { it.id })
    val continuing = ordered.firstOrNull { it.lastOpenedAt != null }
    val visible = ordered.filter {
        (!favoritesOnly || it.isBookmarked) && (query.isBlank() || it.title.contains(query, true) || it.author?.contains(query, true) == true)
    }
}

fun comicSpread(index: Int, pageCount: Int, appearance: ReadingAppearance, widthDp: Int): List<Int> {
    if (pageCount <= 0) return emptyList()
    val count = appearance.columns(widthDp)
    val start = index.coerceIn(0, pageCount - 1) / count * count
    return (start until minOf(start + count, pageCount)).toList()
}

/** Portable v1 PDF progress is the last visible one-based page divided by count. */
fun resumePdfPage(progress: Double, pageCount: Int): Int =
    if (pageCount <= 0) 0 else (kotlin.math.ceil(progress.safeFraction() * pageCount - 1e-9).toInt() - 1).coerceIn(0, pageCount - 1)

fun resumeComicPage(progress: Double, pageCount: Int): Int =
    kotlin.math.round(progress.safeFraction() * maxOf(pageCount - 1, 0)).toInt()

fun resumeReflowPosition(progress: Double, chapterCount: Int): Pair<Int, Double> {
    if (chapterCount <= 0) return 0 to 0.0
    val scaled = progress.safeFraction() * chapterCount
    val chapter = scaled.toInt().coerceIn(0, chapterCount - 1)
    return chapter to (scaled - chapter).coerceIn(0.0, 1.0)
}
private fun Double.safeFraction() = if(isFinite()) coerceIn(0.0, 1.0) else 0.0

enum class ReaderLayout { SCROLL, PAGE, SPREAD }
data class ReadingAppearance(
    val fontSize: Int = 20,
    val family: String = "Serif",
    val theme: String = "System",
    val layout: ReaderLayout = ReaderLayout.PAGE,
    val customBackground: String = "#fffdf7",
    val customForeground: String = "#292621",
) {
    fun columns(widthDp: Int): Int = if (layout == ReaderLayout.SPREAD && widthDp >= 700) 2 else 1
    fun validated() = copy(fontSize = fontSize.coerceIn(14, 38), family = family.takeIf { it in listOf("Serif", "Sans", "Mono") } ?: "Serif",
        customBackground = customBackground.takeIf { it.matches(Regex("#[0-9a-fA-F]{6}")) } ?: "#fffdf7",
        customForeground = customForeground.takeIf { it.matches(Regex("#[0-9a-fA-F]{6}")) } ?: "#292621")
}
