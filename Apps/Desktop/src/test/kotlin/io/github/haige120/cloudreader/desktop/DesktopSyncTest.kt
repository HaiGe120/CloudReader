package io.github.haige120.cloudreader.desktop

import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Test
import java.nio.file.Files
import io.github.haige120.cloudreader.core.model.*

class DesktopSyncTest {
    @Test fun incomingProgressInvalidatesStaleDeviceAnchorButFavoriteOnlyUpdatesDoNot(){
        val root=Files.createTempDirectory("desktop-incoming-progress")
        try{
            val source=root.resolve("book.txt");Files.writeString(source,"Original book text")
            val repo=FileLibraryRepository(root.resolve("library"))
            val book=(repo.importBook(source) as ImportResult.Imported).book
            repo.savePosition(book.id,.2,"txt:3")
            val initial=repo.manifest()
            val favorite=initial.copy(books=initial.books.map{it.copy(book=it.book.copy(isBookmarked=true,modifiedAt=it.book.modifiedAt+1))})
            repo.installManifest(favorite,emptyMap())
            assertEquals("txt:3",repo.books().single().localLocation)
            val advanced=favorite.copy(books=favorite.books.map{it.copy(book=it.book.copy(progress=.8,modifiedAt=it.book.modifiedAt+1))})
            repo.installManifest(advanced,emptyMap())
            val reopened=FileLibraryRepository(root.resolve("library")).books().single()
            assertEquals(.8,reopened.progress,0.00001);assertNull(reopened.localLocation)
            assertEquals(0,reopened.textOffset);assertTrue(reopened.isFavorite)
        }finally{root.toFile().deleteRecursively()}
    }
    @Test fun folderRoundTripRetainsFavoritesProgressChatAndDeletion()=runBlocking {
        val root=Files.createTempDirectory("desktop-roundtrip")
        val a=FileLibraryRepository(root.resolve("a"));val b=FileLibraryRepository(root.resolve("b"))
        val source=root.resolve("original.txt");Files.writeString(source,"Offline library")
        val book=(a.importBook(source) as ImportResult.Imported).book
        a.setFavorite(book.id,true);a.savePosition(book.id,.5,"txt:5")
        val chatID="00000000-0000-0000-0000-000000000201"
        a.saveChat(ChatRecord(chatID,"Question",messages=listOf(ChatMessage("00000000-0000-0000-0000-000000000202","user","Why?",1.0)),createdAt=1.0,modifiedAt=2.0))
        val stores=listOf("Folder" to {FolderObjectStore(root.resolve("shared"))})
        assertTrue(DesktopSync(a,root.resolve("a-recovery")).sync(stores).startsWith("Synced"))
        assertTrue(DesktopSync(b,root.resolve("b-recovery")).sync(stores).startsWith("Synced"))
        assertTrue(b.books().single().isFavorite);assertEquals(.5,b.books().single().progress,0.0001)
        assertEquals("Why?",b.chats().single().messages.single().text)
        b.remove(b.books().single().id);b.removeChat(chatID)
        DesktopSync(b,root.resolve("b-recovery")).sync(stores)
        DesktopSync(a,root.resolve("a-recovery")).sync(stores)
        assertTrue(a.books().isEmpty());assertTrue(a.chats().isEmpty());assertEquals("Offline library",Files.readString(source))
    }
    @Test fun corruptRemoteContentDoesNotInstallMetadata()=runBlocking {
        val root=Files.createTempDirectory("desktop-corrupt")
        val a=FileLibraryRepository(root.resolve("a"));val b=FileLibraryRepository(root.resolve("b"))
        val source=root.resolve("book.txt");Files.writeString(source,"Verified bytes")
        val book=(a.importBook(source) as ImportResult.Imported).book
        val stores=listOf("Folder" to {FolderObjectStore(root.resolve("shared"))})
        DesktopSync(a,root.resolve("a-recovery")).sync(stores)
        Files.writeString(root.resolve("shared/CloudReader").resolve(PortableContractBridge.objectName(book.id,book.format)),"Corrupt bytes")
        assertTrue(DesktopSync(b,root.resolve("b-recovery")).sync(stores).contains("hash mismatch"))
        assertTrue(b.books().isEmpty())
    }
    @Test fun progressOnlyEditsRetainFavoriteAndLegacyOffset(){
        val root=Files.createTempDirectory("desktop-progress");val source=root.resolve("book.txt");Files.writeString(source,"abcdef")
        val repo=FileLibraryRepository(root.resolve("library"));val book=(repo.importBook(source) as ImportResult.Imported).book
        repo.setFavorite(book.id,true);repo.updateProgress(book.id,3)
        val restored=FileLibraryRepository(root.resolve("library")).books().single()
        assertTrue(restored.isFavorite);assertEquals(3,restored.textOffset)
    }
}
