package io.github.haige120.cloudreader.sync

import android.content.Context
import android.net.Uri
import androidx.documentfile.provider.DocumentFile
import com.jcraft.jsch.ChannelSftp
import com.jcraft.jsch.JSch
import com.jcraft.jsch.SftpException
import io.github.haige120.cloudreader.data.CloudReaderPreferences
import io.github.haige120.cloudreader.data.SecureVault
import java.io.File
import java.security.MessageDigest
import java.util.Base64
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.Credentials
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody

interface RemoteBookStore {
    suspend fun read(name: String): ByteArray?
    suspend fun write(name: String, bytes: ByteArray)
}

class FolderStore(context: Context, treeUri: Uri) : RemoteBookStore {
    private val resolver = context.applicationContext.contentResolver
    private val directory = DocumentFile.fromTreeUri(context, treeUri)
        ?: throw IllegalArgumentException("Choose a writable folder in the document picker.")

    override suspend fun read(name: String): ByteArray? = withContext(Dispatchers.IO) {
        requireSafeObject(name)
        val file = cloudFolder()?.findFile(name) ?: return@withContext null
        resolver.openInputStream(file.uri)?.use { it.readBytes() }
    }

    override suspend fun write(name: String, bytes: ByteArray) = withContext(Dispatchers.IO) {
        requireSafeObject(name)
        val folder = cloudFolder() ?: throw IllegalStateException("The selected folder is no longer writable.")
        val target = folder.findFile(name) ?: folder.createFile("application/octet-stream", name)
            ?: throw IllegalStateException("Could not create $name in the selected folder.")
        resolver.openOutputStream(target.uri, "wt")?.use { it.write(bytes) }
            ?: throw IllegalStateException("Could not open $name in the selected folder.")
    }

    private fun cloudFolder(): DocumentFile? = directory.findFile("CloudReader") ?: directory.createDirectory("CloudReader")
}

class WebDavStore(private val settings: CloudReaderPreferences, private val vault: SecureVault, private val client: OkHttpClient = OkHttpClient()) : RemoteBookStore {
    override suspend fun read(name: String): ByteArray? = withContext(Dispatchers.IO) {
        val base = baseUrl()
        val credentials = credentials()
        val request = Request.Builder().url("$base/CloudReader/${encode(name)}")
            .header("Authorization", Credentials.basic(credentials.first, credentials.second)).get().build()
        client.newCall(request).execute().use { response ->
            if (response.code == 404) return@withContext null
            if (!response.isSuccessful) throw IllegalStateException("WebDAV returned HTTP ${response.code}")
            response.body?.bytes() ?: ByteArray(0)
        }
    }

    override suspend fun write(name: String, bytes: ByteArray) = withContext(Dispatchers.IO) {
        val base = baseUrl()
        val credentials = credentials()
        val auth = Credentials.basic(credentials.first, credentials.second)
        val folder = Request.Builder().url("$base/CloudReader/").header("Authorization", auth).method("MKCOL", null).build()
        client.newCall(folder).execute().use { if (!it.isSuccessful && it.code != 405) throw IllegalStateException("WebDAV folder setup returned HTTP ${it.code}") }
        val request = Request.Builder().url("$base/CloudReader/${encode(name)}").header("Authorization", auth)
            .put(bytes.toRequestBody()).build()
        client.newCall(request).execute().use { if (!it.isSuccessful) throw IllegalStateException("WebDAV upload returned HTTP ${it.code}") }
    }

    private suspend fun baseUrl(): String {
        val value = settings.get("webdav.url")?.trimEnd('/') ?: throw IllegalStateException("Add a WebDAV URL in Settings.")
        val uri = Uri.parse(value)
        require(uri.scheme == "https" && !uri.host.isNullOrBlank()) { "WebDAV requires an HTTPS server URL." }
        return value
    }
    private fun credentials(): Pair<String, String> {
        val user = vault.get("webdav.username") ?: throw IllegalStateException("Add WebDAV credentials in Settings.")
        val password = vault.get("webdav.password") ?: throw IllegalStateException("Add WebDAV credentials in Settings.")
        return user to password
    }
}

class SftpStore(context: Context, private val vault: SecureVault) : RemoteBookStore {
    private data class Connection(val client: ChannelSftp, val session: com.jcraft.jsch.Session)
    @Volatile private var connection: Connection? = null
    private val knownHosts = File(context.applicationContext.noBackupFilesDir, "sftp_known_hosts")

    override suspend fun read(name: String): ByteArray? = withContext(Dispatchers.IO) {
        requireSafeObject(name)
        val channel = connect()
        try { channel.client.get(path(name)).use { it.readBytes() } } catch (error: SftpException) {
            if (error.id == ChannelSftp.SSH_FX_NO_SUCH_FILE) null else throw error
        }
    }

    override suspend fun write(name: String, bytes: ByteArray) = withContext(Dispatchers.IO) {
        requireSafeObject(name)
        val channel = connect()
        channel.client.put(bytes.inputStream(), path(name), ChannelSftp.OVERWRITE)
    }

    private fun connect(): Connection {
        connection?.takeIf { it.session.isConnected }?.let { return it }
        val host = vault.get("sftp.host") ?: throw IllegalStateException("Add the SFTP server in Settings.")
        val port = vault.get("sftp.port")?.toIntOrNull() ?: 22
        val username = vault.get("sftp.username") ?: throw IllegalStateException("Add the SFTP username in Settings.")
        val password = vault.get("sftp.password") ?: throw IllegalStateException("Add the SFTP password in Settings.")
        val directory = vault.get("sftp.directory")?.trim('/')?.takeIf(String::isNotBlank) ?: "CloudReader"
        val pin = vault.get("sftp.hostKey")?.trim() ?: throw IllegalStateException("Pin the SFTP host key before connecting.")
        val pieces = pin.split(Regex("\\s+"))
        require(pieces.size >= 2 && pieces[0].startsWith("ssh-")) { "Enter the server's OpenSSH public host key." }
        val knownHost = if (port == 22) host else "[$host]:$port"
        knownHosts.writeText("$knownHost ${pieces[0]} ${pieces[1]}\n")
        val jsch = JSch().apply { setKnownHosts(knownHosts.absolutePath) }
        val session = jsch.getSession(username, host, port).apply {
            setPassword(password)
            setConfig("StrictHostKeyChecking", "yes")
            setConfig("PreferredAuthentications", "password")
            connect(18_000)
        }
        try {
            val channel = session.openChannel("sftp") as ChannelSftp
            channel.connect(18_000)
            ensureRemoteDirectory(channel, directory)
            return Connection(channel, session).also { connection = it }
        } catch (error: Throwable) {
            session.disconnect(); throw error
        }
    }

    private fun ensureRemoteDirectory(channel: ChannelSftp, directory: String) {
        for (part in directory.split('/').filter(String::isNotBlank)) {
            try { channel.cd(part) } catch (_: SftpException) { channel.mkdir(part); channel.cd(part) }
        }
    }

    private fun path(name: String): String = name
}

internal fun requireSafeObject(name: String) {
    require(name.matches(Regex("[A-Za-z0-9._-]{1,180}")) && !name.contains("..")) { "Unsafe sync object name." }
}

internal fun encode(path: String): String = java.net.URLEncoder.encode(path, Charsets.UTF_8.name()).replace("+", "%20")

internal fun sha256(bytes: ByteArray): String = MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }
