package io.github.haige120.cloudreader.desktop

import io.github.haige120.cloudreader.core.reader.PublicationLoader
import java.io.PushbackInputStream
import java.nio.file.Files

/** Called only after the user enables book context and chooses Send. */
internal fun readDesktopBookContext(book:BookRecord,limit:Int=18_000):String?{
    require(limit>=0)
    if(limit==0)return ""
    val text=when(book.format){
        BookFormat.TXT->PushbackInputStream(book.sourcePath.toFile().inputStream().buffered(),3).use{input->
            val prefix=ByteArray(3);val count=input.read(prefix)
            val (charset,bom)=when{
                count>=2&&prefix[0]==0xff.toByte()&&prefix[1]==0xfe.toByte()->Charsets.UTF_16LE to 2
                count>=2&&prefix[0]==0xfe.toByte()&&prefix[1]==0xff.toByte()->Charsets.UTF_16BE to 2
                count>=3&&prefix[0]==0xef.toByte()&&prefix[1]==0xbb.toByte()&&prefix[2]==0xbf.toByte()->Charsets.UTF_8 to 3
                else->Charsets.UTF_8 to 0
            }
            if(count>bom)input.unread(prefix,bom,count-bom)
            input.reader(charset).use{reader->buildString{val buffer=CharArray(minOf(1024,limit));while(length<limit){val n=reader.read(buffer,0,minOf(buffer.size,limit-length));if(n<0)break;append(buffer,0,n)}}}
        }
        BookFormat.PDF->org.apache.pdfbox.Loader.loadPDF(book.sourcePath.toFile()).use{document->
            val result=StringBuilder()
            val full=object:RuntimeException(null,null,false,false){}
            val writer=object:java.io.Writer(){
                override fun write(chars:CharArray,offset:Int,count:Int){val take=minOf(count,limit-result.length);if(take>0)result.append(chars,offset,take);if(take<count)throw full}
                override fun flush()=Unit
                override fun close()=Unit
            }
            try{org.apache.pdfbox.text.PDFTextStripper().writeText(document,writer)}catch(failure:RuntimeException){if(failure!==full)throw failure}
            result.toString()
        }
        BookFormat.EPUB,BookFormat.FB2->{
            val cache=Files.createTempDirectory("cloudreader-consented-context").toFile()
            try{val publication=PublicationLoader.prepare(book.sourcePath.toFile(),cache,book.format.extension)
                buildString{for(chapter in publication.chapters){if(length>=limit)break;append(org.jsoup.Jsoup.parse(chapter.file,"UTF-8").text().take(limit-length));if(length<limit)append('\n')}}
            }finally{cache.deleteRecursively()}
        }
        else->return null
    }
    return if(text.lastOrNull()?.isHighSurrogate()==true)text.dropLast(1)else text
}
