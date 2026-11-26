package io.github.haige120.cloudreader.core

import io.github.haige120.cloudreader.core.reader.PublicationCover
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream

class PublicationCoverTest {
    @get:Rule val temp = TemporaryFolder()
    private val art = byteArrayOf(1, 2, 3)

    private fun archive(vararg entries: Pair<String, ByteArray>): File = temp.newFile().also { file ->
        ZipOutputStream(file.outputStream()).use { zip ->
            entries.forEach { (name, bytes) ->
                zip.putNextEntry(ZipEntry(name))
                zip.write(bytes)
                zip.closeEntry()
            }
        }
    }

    private fun epub(packageXml: String, vararg entries: Pair<String, ByteArray>) = archive(
        "META-INF/container.xml" to "<container><rootfiles><rootfile full-path='Book/package.opf'/></rootfiles></container>".toByteArray(),
        "Book/package.opf" to packageXml.toByteArray(), *entries)

    @Test fun epub3UsesDesignatedCoverEvenWhenAnotherImageComesFirst() {
        val file = epub("""<package><manifest><item href="other.png" media-type="image/png"/>
            <item href="../Art/the%20cover.png" properties="cover-image" media-type="image/png"/></manifest></package>""",
            "Art/the cover.png" to art, "Book/other.png" to byteArrayOf(9))
        assertArrayEquals(art, PublicationCover.image(file, "epub"))
    }

    @Test fun epub2FollowsMetadataToWrappedImage() {
        val file = epub("""<package><metadata><meta name="cover" content="jacket"/></metadata><manifest>
            <item id="jacket" href="cover.xhtml" media-type="application/xhtml+xml"/></manifest></package>""",
            "Book/cover.xhtml" to "<html><body><svg><image xlink:href='art.png'/></svg></body></html>".toByteArray(),
            "Book/art.png" to art)
        assertArrayEquals(art, PublicationCover.image(file, "epub"))
    }

    @Test fun ordinaryFirstChapterWithInlineIllustrationIsNotACover() {
        val file = epub("""<package><manifest><item id="ch" href="one.xhtml"/></manifest><spine><itemref idref="ch"/></spine></package>""",
            "Book/one.xhtml" to "<html><body>Chapter one<img src='art.png'/></body></html>".toByteArray(), "Book/art.png" to art)
        assertNull(PublicationCover.image(file, "epub"))
    }

    @Test fun comicUsesFirstPageInReadingOrderAndSkipsHiddenFiles() {
        val file = archive("10.jpg" to byteArrayOf(9), "__MACOSX/._1.jpg" to byteArrayOf(8), "2.jpg" to art)
        assertArrayEquals(art, PublicationCover.image(file, "cbz"))
    }

    @Test fun fb2UsesOnlyTheReferencedCoverBinary() {
        val file = temp.newFile().apply { writeText("""<FictionBook><description><title-info><coverpage>
            <image l:href="#front"/></coverpage></title-info></description><binary id="other">CQ==</binary>
            <binary id="front">AQID</binary></FictionBook>""") }
        assertArrayEquals(art, PublicationCover.image(file, "fb2"))
    }
}
