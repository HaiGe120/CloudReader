package io.github.haige120.cloudreader

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class ReaderTextTest {
    @Test fun decodesUtf8AndUtf16WithByteOrderMarksIncludingCjk() {
        val sample = "CloudReader · 中文 · こんにちは"
        val utf8 = byteArrayOf(0xEF.toByte(), 0xBB.toByte(), 0xBF.toByte()) + sample.toByteArray(Charsets.UTF_8)
        val utf16le = byteArrayOf(0xFF.toByte(), 0xFE.toByte()) + sample.toByteArray(Charsets.UTF_16LE)
        val utf16be = byteArrayOf(0xFE.toByte(), 0xFF.toByte()) + sample.toByteArray(Charsets.UTF_16BE)
        assertEquals(sample, decodeText(utf8))
        assertEquals(sample, decodeText(utf16le))
        assertEquals(sample, decodeText(utf16be))
    }

    @Test fun facingPageRangesRetainEveryCharacterAndSurrogatePair() {
        val text = ("CloudReader 中文 paragraph. 🙂\n".repeat(80)) + "end"
        val starts = pageStartOffsets(text, 97)
        assertEquals(0, starts.first())
        assertTrue(starts.zipWithNext().all { (first, second) -> second > first })
        val rebuilt = starts.mapIndexed { index, start -> text.substring(start, starts.getOrElse(index + 1) { text.length }) }.joinToString("")
        assertEquals(text, rebuilt)
    }

    @Test fun readerSessionRestoresOnlyValidUtf16OffsetsAndFallsBackToFraction() {
        assertEquals(7, validTextOffset("txt:7:utf16", 12))
        assertEquals(12, validTextOffset("txt:12:utf16", 12))
        assertEquals(null, validTextOffset("txt:13:utf16", 12))
        assertEquals(null, validTextOffset("txt:-1:utf16", 12))
        assertEquals(null, validTextOffset("txt:7:unknown", 12))
        assertEquals(null, validTextOffset("pdf:3", 12))
        assertEquals(3, textOffsetForProgress(0.25, 12))
        assertEquals(0, textOffsetForProgress(-1.0, 12))
        assertEquals(12, textOffsetForProgress(2.0, 12))
    }
}
