package io.github.haige120.cloudreader.desktop

import org.junit.Assert.*
import org.junit.Test
import java.nio.file.Files
import java.time.Instant

class DesktopBookContextTest{
    @Test fun textContextIsBomAwareBoundedAndKeepsTheOriginal(){
        val root=Files.createTempDirectory("desktop-context")
        try{
            val file=root.resolve("text.txt");val bytes=byteArrayOf(0xff.toByte(),0xfe.toByte())+"你好 World".repeat(10000).toByteArray(Charsets.UTF_16LE)
            Files.write(file,bytes)
            val book=BookRecord(newBookId(),"Text",BookFormat.TXT,file,Instant.now())
            val context=readDesktopBookContext(book)!!
            assertTrue(context.startsWith("你好 World"));assertEquals(18000,context.length);assertArrayEquals(bytes,Files.readAllBytes(file))
        }finally{root.toFile().deleteRecursively()}
    }
    @Test fun contextNeverReturnsHalfOfASupplementaryCharacter(){
        val root=Files.createTempDirectory("desktop-context-unicode")
        try{val file=root.resolve("text.txt");Files.writeString(file,"abc😀rest")
            assertEquals("abc",readDesktopBookContext(BookRecord(newBookId(),"Text",BookFormat.TXT,file,Instant.now()),4))
        }finally{root.toFile().deleteRecursively()}
    }
}
