package io.github.haige120.cloudreader.ai

import java.io.BufferedInputStream
import java.io.File
import java.io.InputStreamReader
import java.io.PushbackInputStream
import java.nio.charset.Charset

internal const val MAX_BOOK_CONTEXT_CHARS = 18_000

/** Reads at most [maxChars] UTF-16 code units from a local text file, without retaining the rest. */
internal fun readBoundedBookContext(file: File, maxChars: Int = MAX_BOOK_CONTEXT_CHARS): String {
    require(maxChars >= 0)
    if (maxChars == 0) return ""

    return PushbackInputStream(BufferedInputStream(file.inputStream()), 3).use { input ->
        val prefix = ByteArray(3)
        val count = input.read(prefix)
        val (charset, bomLength) = when {
            count >= 2 && prefix[0] == 0xFF.toByte() && prefix[1] == 0xFE.toByte() -> Charsets.UTF_16LE to 2
            count >= 2 && prefix[0] == 0xFE.toByte() && prefix[1] == 0xFF.toByte() -> Charsets.UTF_16BE to 2
            count >= 3 && prefix[0] == 0xEF.toByte() && prefix[1] == 0xBB.toByte() && prefix[2] == 0xBF.toByte() -> Charsets.UTF_8 to 3
            else -> Charsets.UTF_8 to 0
        }
        if (count > bomLength) input.unread(prefix, bomLength, count - bomLength)

        InputStreamReader(input, charset).use { reader ->
            val result = StringBuilder(maxChars)
            val buffer = CharArray(minOf(1024, maxChars))
            while (result.length < maxChars) {
                val read = reader.read(buffer, 0, minOf(buffer.size, maxChars - result.length))
                if (read < 0) break
                result.append(buffer, 0, read)
            }
            // A supplementary Unicode character occupies a surrogate pair. If the cap lands
            // between its halves, discard the high surrogate rather than return half a character.
            if (result.length == maxChars && result.last().isHighSurrogate()) {
                val next = reader.read()
                if (next in Char.MIN_LOW_SURROGATE.code..Char.MAX_LOW_SURROGATE.code) {
                    result.setLength(maxChars - 1)
                }
            }
            result.toString()
        }
    }
}
