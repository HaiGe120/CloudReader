package io.github.haige120.cloudreader

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class NativeReaderChromePolicyTest {
    @Test fun `center tap leaves both page turn edges to Readium`() {
        assertFalse(isReaderChromeCenterTap(80f, 400))
        assertFalse(isReaderChromeCenterTap(120f, 400))
        assertTrue(isReaderChromeCenterTap(121f, 400))
        assertTrue(isReaderChromeCenterTap(200f, 400))
        assertTrue(isReaderChromeCenterTap(279f, 400))
        assertFalse(isReaderChromeCenterTap(280f, 400))
        assertFalse(isReaderChromeCenterTap(320f, 400))
    }

    @Test fun `Readium minimum edge width and unavailable viewport cannot hide chrome`() {
        assertFalse(isReaderChromeCenterTap(75f, 200))
        assertTrue(isReaderChromeCenterTap(100f, 200))
        assertFalse(isReaderChromeCenterTap(125f, 200))
        assertFalse(isReaderChromeCenterTap(70f, 140))
        assertFalse(isReaderChromeCenterTap(0f, 0))
        assertFalse(isReaderChromeCenterTap(Float.NaN, 400))
        assertFalse(isReaderChromeCenterTap(Float.POSITIVE_INFINITY, 400))
    }
}
