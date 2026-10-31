package io.github.haige120.cloudreader.core

import io.github.haige120.cloudreader.core.reader.PublicationLoader
import org.junit.Assert.*
import org.junit.Test
import java.nio.file.Files
import java.util.zip.ZipOutputStream
import java.util.zip.ZipEntry

class PublicationLoaderTest {
    private fun archive(entries: Map<String,String>, extension: String = "epub"): java.io.File {
        val source = Files.createTempFile("publication", ".$extension").toFile()
        ZipOutputStream(source.outputStream()).use { zip -> entries.forEach { (name,text) -> zip.putNextEntry(ZipEntry(name));zip.write(text.toByteArray());zip.closeEntry() } }
        return source
    }
    @Test fun epubFollowsSpineAndRemovesActiveAndRemoteContent() {
        val source=archive(mapOf(
            "META-INF/container.xml" to "<container><rootfiles><rootfile full-path='OPS/package.opf'/></rootfiles></container>",
            "OPS/package.opf" to "<package><manifest><item id='one' href='one.xhtml'/><item id='two' href='two.xhtml'/></manifest><spine><itemref idref='two'/><itemref idref='one'/></spine></package>",
            "OPS/one.xhtml" to "<html><body><h1>One</h1><p>Chapter one.</p></body></html>",
            "OPS/two.xhtml" to "<html><body><h1>Two</h1><p>Before <strong>bold</strong> after.</p><script>fetch('https://example.com')</script><img src='https://example.com/tracker.png'/><a href='file:///etc/passwd'>Unsafe</a></body></html>"))
        val original=source.readBytes()
        val prepared=PublicationLoader.prepare(source,Files.createTempDirectory("reader-cache").toFile())
        try {
            assertEquals(listOf("Two","One"),prepared.chapters.map{it.title})
            val html=prepared.chapters.first().file.readText()
            assertTrue(html.contains("Before <strong>bold</strong> after."))
            assertFalse(html.contains("<script"));assertFalse(html.contains("tracker.png"));assertFalse(html.contains("file:///etc"))
            assertArrayEquals(original,source.readBytes())
        } finally { prepared.root.deleteRecursively();source.delete() }
    }
    @Test fun rejectsTraversalAndCleansTheFailedPreparation() {
        val source=archive(mapOf("../outside.txt" to "unsafe"))
        val cache=Files.createTempDirectory("reader-cache").toFile()
        try { PublicationLoader.prepare(source,cache);fail("Traversal must fail") } catch(_:IllegalArgumentException) { }
        assertTrue(cache.listFiles().orEmpty().isEmpty())
        assertFalse(java.io.File(cache.parentFile,"outside.txt").exists())
    }
    @Test fun fb2PreservesMixedTextNotesAndEmbeddedImages() {
        val source=Files.createTempFile("publication",".fb2").toFile()
        source.writeText("""<FictionBook xmlns:l="http://www.w3.org/1999/xlink"><body><section><title><p>Chapter</p></title><p>Before <emphasis>inside</emphasis> after <a l:href="#note">note</a>.</p><image l:href="#cover"/></section><section id="note"><p>A note.</p></section></body><binary id="cover" content-type="image/png">aGVsbG8=</binary></FictionBook>""")
        val prepared=PublicationLoader.prepare(source,Files.createTempDirectory("reader-cache").toFile())
        val html=prepared.chapters.single().file.readText()
        assertTrue(html.contains("Before <em>inside</em> after"));assertTrue(html.contains("#note"));assertTrue(html.contains("image-0.png"))
        assertTrue(java.io.File(prepared.root,"image-0.png").isFile)
        prepared.root.deleteRecursively()
    }
    @Test fun comicUsesNaturalOrderAndKeepsOddLastPage() {
        val source=archive(mapOf("10.jpg" to "ten","2.jpg" to "two","1.jpg" to "one"),"cbz")
        val prepared=PublicationLoader.prepare(source,Files.createTempDirectory("reader-cache").toFile())
        assertEquals(listOf("1.jpg","2.jpg","10.jpg"),prepared.images.map{it.name})
        prepared.root.deleteRecursively()
    }
    @Test fun absoluteAndBackslashPathsCannotEscape() {
        val root=Files.createTempDirectory("reader-root").toFile()
        listOf("/etc/passwd","C:/windows/file","..\\outside","../../outside").forEach { name ->
            try { PublicationLoader.safeFile(root,name);fail("Unsafe path: $name") } catch(_:IllegalArgumentException) { }
        }
    }
}
