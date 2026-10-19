package io.github.haige120.cloudreader.sync

import org.junit.Assert.assertThrows
import org.junit.Test

class RemoteObjectNameTest {
    @Test fun rejectsPathsAndTraversalAsRemoteObjectNames() {
        assertThrows(IllegalArgumentException::class.java) { requireSafeObject("../manifest.json") }
        assertThrows(IllegalArgumentException::class.java) { requireSafeObject("folder/book-ABC.txt") }
        requireSafeObject("book-0E7B7B49-9652-4E82-BA2E-84F58CC90D46.txt")
    }
}
