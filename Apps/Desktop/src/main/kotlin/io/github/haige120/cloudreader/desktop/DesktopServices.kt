package io.github.haige120.cloudreader.desktop

import io.github.haige120.cloudreader.core.application.ManifestMerger
import io.github.haige120.cloudreader.core.contract.*
import io.github.haige120.cloudreader.core.assistant.AIProfile
import io.github.haige120.cloudreader.core.ports.RemoteObjectStore
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import okhttp3.*
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.Credentials
import java.nio.file.*
import java.util.Properties
import java.util.concurrent.TimeUnit

class DesktopSettings(private val file: Path) {
    private val values = Properties().apply { if (Files.exists(file)) Files.newBufferedReader(file).use(::load) }
    @Synchronized fun get(key: String, default: String = ""): String = values.getProperty(key, default)
    @Synchronized fun save(updates: Map<String, String>) {
        updates.forEach { (key, value) -> values.setProperty(key, value) }
        val writer = java.io.StringWriter().also { values.store(it, "CloudReader settings; credentials are stored separately") }
        atomicWrite(file, writer.toString().toByteArray())
    }
    fun profile() = AIProfile(get("ai.name", "My AI"), get("ai.protocol", "openAIResponses"), get("ai.endpoint"), get("ai.model"))
}

/** OS secret services are used when available; unavailable services use session memory unless opted in. */
class DesktopSecrets(root: Path, settings: DesktopSettings) {
    private val os = System.getProperty("os.name").lowercase()
    private val session = mutableMapOf<String, String>()
    private val fallback = if (settings.get("credentials.plaintext") == "true") OptInPlaintextCredentialStore(root.resolve("credentials.properties"), true) else null
    val description: String get() = when {
        fallback != null -> "Plaintext credential storage was explicitly enabled on this device."
        os.contains("win") -> "Windows Credential Manager; unavailable credentials remain session-only."
        os.contains("linux") -> "Linux Secret Service via secret-tool; unavailable credentials remain session-only."
        else -> "Session-only credentials on this development host."
    }
    @Synchronized fun read(key: String): String? = session[key] ?: fallback?.read("CloudReader", key) ?: runCatching {
        when {
            os.contains("linux") -> command(listOf("secret-tool", "lookup", "application", "CloudReader", "account", key)).takeIf { it.isNotEmpty() }
            os.contains("win") -> windows(key, null).takeIf { it.isNotEmpty() }
            else -> null
        }
    }.getOrNull()?.also { session[key] = it }
    @Synchronized fun write(key: String, value: String) {
        session[key] = value
        if (fallback != null) { fallback.write("CloudReader", key, value); return }
        runCatching {
            when {
                os.contains("linux") -> command(listOf("secret-tool", "store", "--label=CloudReader", "application", "CloudReader", "account", key), value)
                os.contains("win") -> windows(key, value)
            }
        }
    }
    private fun windows(key: String, secret: String?): String {
        require(key.matches(Regex("[A-Za-z0-9._-]+")))
        val script = WINDOWS_VAULT + if (secret == null) "[CloudReaderVault]::Read('CloudReader/$key')" else "[CloudReaderVault]::Write('CloudReader/$key',[Console]::In.ReadToEnd())"
        return command(listOf("powershell.exe", "-NoProfile", "-NonInteractive", "-Command", script), secret)
    }
    private fun command(args: List<String>, input: String? = null): String {
        val process = ProcessBuilder(args).redirectError(ProcessBuilder.Redirect.DISCARD).start()
        process.outputStream.use { if (input != null) it.write(input.toByteArray(Charsets.UTF_8)) }
        if (!process.waitFor(15, TimeUnit.SECONDS)) { process.destroyForcibly(); error("Credential service timed out") }
        check(process.exitValue() == 0) { "Credential service unavailable" }
        return process.inputStream.bufferedReader().readText().trimEnd('\r', '\n')
    }
    companion object {
        private val WINDOWS_VAULT = """
Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Runtime.InteropServices;
public static class CloudReaderVault {
 [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)] struct Credential {
  public uint Flags,Type; public string TargetName,Comment; public System.Runtime.InteropServices.ComTypes.FILETIME LastWritten;
  public uint CredentialBlobSize; public IntPtr CredentialBlob; public uint Persist,AttributeCount; public IntPtr Attributes; public string TargetAlias,UserName;
 }
 [DllImport("advapi32", EntryPoint="CredReadW", CharSet=CharSet.Unicode, SetLastError=true)] static extern bool CredRead(string target,uint type,uint flags,out IntPtr credential);
 [DllImport("advapi32", EntryPoint="CredWriteW", CharSet=CharSet.Unicode, SetLastError=true)] static extern bool CredWrite(ref Credential credential,uint flags);
 [DllImport("advapi32")] static extern void CredFree(IntPtr ptr);
 public static string Read(string target) { IntPtr p; if(!CredRead(target,1,0,out p)) return ""; try { var c=(Credential)Marshal.PtrToStructure(p,typeof(Credential)); byte[] b=new byte[c.CredentialBlobSize]; Marshal.Copy(c.CredentialBlob,b,0,b.Length); return Encoding.UTF8.GetString(b); } finally { CredFree(p); } }
 public static void Write(string target,string value) { byte[] b=Encoding.UTF8.GetBytes(value); IntPtr p=Marshal.AllocHGlobal(b.Length); try { Marshal.Copy(b,0,p,b.Length); var c=new Credential { Type=1,TargetName=target,CredentialBlobSize=(uint)b.Length,CredentialBlob=p,Persist=2,UserName="CloudReader" }; if(!CredWrite(ref c,0)) throw new Exception("Credential storage failed"); } finally { Marshal.FreeHGlobal(p); } }
}
'@
""".trimIndent()+"\n"
    }
}

class FolderObjectStore(folder: Path) : RemoteObjectStore {
    private val root = folder.resolve("CloudReader")
    init { Files.createDirectories(root) }
    private fun path(name: String): Path {
        require(name == "manifest.json" || name.matches(Regex("book-[A-F0-9-]+\\.[a-z0-9]+")))
        return root.resolve(name).also { require(!Files.isSymbolicLink(it)) { "Sync objects cannot be symbolic links." } }
    }
    override suspend fun read(name: String): ByteArray? = path(name).let { if (Files.exists(it)) Files.readAllBytes(it) else null }
    override suspend fun write(name: String, bytes: ByteArray) = atomicWrite(path(name), bytes)
    override fun close() = Unit
}

class WebDavObjectStore(url: String, user: String, password: String) : RemoteObjectStore {
    private val base = java.net.URI(url.trimEnd('/') + "/CloudReader/").also { require(it.scheme == "https" && it.host != null && it.userInfo == null) { "Use an HTTPS WebDAV URL." } }.toString()
    private val auth = Credentials.basic(user, password)
    private val http = OkHttpClient.Builder().followRedirects(false).callTimeout(90, TimeUnit.SECONDS).build()
    private fun request(name: String) = Request.Builder().url(base + name).header("Authorization", auth)
    override suspend fun read(name: String): ByteArray? {
        http.newCall(request(name).get().build()).execute().use { response ->
            if (response.code == 404) return null
            check(response.isSuccessful) { "WebDAV returned HTTP ${response.code}." }
            val stream = response.body?.byteStream() ?: error("WebDAV returned no data")
            return stream.use { boundedBytes(it, if (name == "manifest.json") 16 * 1024 * 1024 else 256 * 1024 * 1024) }
        }
    }
    override suspend fun write(name: String, bytes: ByteArray) {
        http.newCall(Request.Builder().url(base).header("Authorization", auth).method("MKCOL", null).build()).execute().use {
            check(it.isSuccessful || it.code == 405) { "WebDAV folder setup returned HTTP ${it.code}." }
        }
        http.newCall(request(name).put(bytes.toRequestBody()).build()).execute().use { check(it.isSuccessful) { "WebDAV write returned HTTP ${it.code}." } }
    }
    override fun close() { http.dispatcher.cancelAll(); http.connectionPool.evictAll() }
}
internal fun boundedBytes(input: java.io.InputStream, limit: Int): ByteArray {
    val output = java.io.ByteArrayOutputStream(); val buffer = ByteArray(32 * 1024)
    while (true) { val n = input.read(buffer); if (n < 0) break; require(output.size().toLong() + n <= limit) { "Object exceeds the transfer limit." }; output.write(buffer,0,n) }
    return output.toByteArray()
}

class DesktopSync(private val library: FileLibraryRepository, private val recovery: Path) {
    private val mutex = Mutex()
    suspend fun sync(stores: List<Pair<String, () -> RemoteObjectStore>>): String = mutex.withLock {
        withContext(Dispatchers.IO) {
            require(stores.isNotEmpty()) { "Choose a sync destination in Settings first." }
            val failures = linkedMapOf<String,String>()
            // A second pass propagates a book first discovered in the last destination to earlier ones.
            repeat(2) { stores.forEach { (label, factory) ->
                try { factory().use { store ->
                    val remote = store.read("manifest.json")?.let(SyncCodec::manifestFromJson) ?: SyncManifest()
                    val local = library.manifest()
                    val result = ManifestMerger.merge(local, remote)
                    if (result.recovery.isNotEmpty()) {
                        Files.createDirectories(recovery.parent)
                        Files.writeString(recovery, result.recovery.joinToString("\n", postfix="\n"), StandardOpenOption.CREATE, StandardOpenOption.APPEND)
                    }
                    val downloaded = mutableMapOf<String,ByteArray>()
                    for (item in result.manifest.books) {
                        if (local.books.none { it.book.id == item.book.id && it.sha256 == item.sha256 }) {
                            val bytes = store.read(SyncCodec.bookObjectName(item.book)) ?: error("Missing remote content for ${item.book.title}.")
                            require(digest(bytes) == item.sha256) { "Content hash mismatch for ${item.book.title}." }
                            downloaded[item.book.id] = bytes
                        }
                    }
                    // Re-read after suspended I/O so local progress/favorite/chat edits are retained.
                    val latest = ManifestMerger.merge(library.manifest(), result.manifest).manifest
                    for (item in latest.books) {
                        if (remote.books.none { it.book.id == item.book.id && it.sha256 == item.sha256 }) {
                            val bytes = downloaded[item.book.id] ?: Files.newInputStream(library.content(item.book.id)).use { boundedBytes(it,256*1024*1024) }
                            store.write(SyncCodec.bookObjectName(item.book), bytes)
                        }
                    }
                    library.installManifest(latest, downloaded)
                    store.write("manifest.json", SyncCodec.manifestToBytes(latest))
                    failures.remove(label)
                } } catch (cancelled: kotlinx.coroutines.CancellationException) { throw cancelled }
                catch (failure: Exception) { failures[label] = failure.message ?: "Sync failed" }
            } }
            if (failures.isEmpty()) "Synced to ${stores.size} destinations" else failures.entries.joinToString("\n") { "${it.key}: ${it.value}" }
        }
    }
}


fun desktopStores(settings:DesktopSettings,secrets:DesktopSecrets):List<Pair<String,()->RemoteObjectStore>> {
    val stores=mutableListOf<Pair<String,()->RemoteObjectStore>>()
    val vault=DesktopVault(secrets,settings)
    if(settings.get("folder.enabled")=="true"&&settings.get("folder.path").isNotBlank())stores+="Folder" to {FolderObjectStore(Path.of(settings.get("folder.path")))}
    if(settings.get("webdav.enabled")=="true")stores+="WebDAV" to {WebDavObjectStore(settings.get("webdav.url"),settings.get("webdav.user"),secrets.read("webdav.password").orEmpty())}
    if(settings.get("googleDrive.enabled")=="true")stores+="Google Drive" to {DesktopOAuth(settings,secrets).refreshGoogle();DesktopGoogleStore(vault)}
    if(settings.get("dropbox.enabled")=="true")stores+="Dropbox" to {DesktopDropboxStore(vault,DesktopProviderPreferences(settings))}
    if(settings.get("pcloud.enabled")=="true")stores+="pCloud" to {DesktopPCloudStore(vault)}
    if(settings.get("sftp.enabled")=="true")stores+="SFTP" to {DesktopSftpStore(vault)}
    return stores
}
