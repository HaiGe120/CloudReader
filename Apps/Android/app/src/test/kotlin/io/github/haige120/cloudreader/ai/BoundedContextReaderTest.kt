package io.github.haige120.cloudreader.ai

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class BoundedContextReaderTest {
    @Test fun largeFileReadsOnlyTheRequestedPrefix() = withTempFile("a".repeat(2_000_000).toByteArray()) { file ->
        val result = readBoundedBookContext(file, 37)
        assertEquals("a".repeat(37), result)
        assertEquals(37, result.length)
    }

    @Test fun defaultLimitIsEighteenThousandCharacters() = withTempFile("z".repeat(20_000).toByteArray()) { file ->
        assertEquals(18_000, readBoundedBookContext(file).length)
    }

    @Test fun supportsUtf8AndUtf16BomEncodings() {
        val cases = listOf(
            byteArrayOf(0xEF.toByte(), 0xBB.toByte(), 0xBF.toByte()) + "Hello 🌍".toByteArray(Charsets.UTF_8),
            byteArrayOf(0xFF.toByte(), 0xFE.toByte()) + "Hello 🌍".toByteArray(Charsets.UTF_16LE),
            byteArrayOf(0xFE.toByte(), 0xFF.toByte()) + "Hello 🌍".toByteArray(Charsets.UTF_16BE),
        )
        cases.forEach { bytes -> withTempFile(bytes) { file ->
            assertEquals("Hello 🌍", readBoundedBookContext(file))
        } }
    }

    @Test fun doesNotReturnHalfOfASurrogatePairAtTheLimit() = withTempFile("ab🌍tail".toByteArray(Charsets.UTF_8)) { file ->
        val result = readBoundedBookContext(file, 3)
        assertEquals("ab", result)
        assertTrue(result.none { it.isSurrogate() })
    }

    @Test fun utf16BomReaderAlsoKeepsSurrogatePairsWholeAtTheLimit() = withTempFile(
        byteArrayOf(0xFF.toByte(), 0xFE.toByte()) + "ab🌍tail".toByteArray(Charsets.UTF_16LE),
    ) { file ->
        assertEquals("ab", readBoundedBookContext(file, 3))
    }

    @Test fun acceptsPlainUtf8WithoutBom() = withTempFile("café".toByteArray(Charsets.UTF_8)) { file ->
        assertEquals("café", readBoundedBookContext(file))
    }

    private fun withTempFile(bytes: ByteArray, block: (File) -> Unit) {
        val file = File.createTempFile("cloudreader-context", ".txt")
        try {
            file.writeBytes(bytes)
            block(file)
        } finally {
            file.delete()
        }
    }
}
