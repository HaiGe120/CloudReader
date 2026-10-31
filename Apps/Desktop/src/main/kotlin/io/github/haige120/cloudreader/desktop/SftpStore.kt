package io.github.haige120.cloudreader.desktop
import com.jcraft.jsch.*
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
class DesktopSftpStore(private val vault: DesktopVault) : DesktopRemoteStore {
    private data class Connection(val client: ChannelSftp, val session: com.jcraft.jsch.Session)
    @Volatile private var connection: Connection? = null

    override fun close() {
        val active = connection
        connection = null
        active?.client?.disconnect()
        active?.session?.disconnect()
    }

    override suspend fun read(name: String): ByteArray? = withContext(Dispatchers.IO) {
        require(name == "manifest.json" || name.matches(Regex("book-[A-F0-9-]+\\.[a-z0-9]+")))
        val channel = connect()
        try { channel.client.get(path(name)).use { boundedBytes(it, if (name == "manifest.json") 16*1024*1024 else 256*1024*1024) } } catch (error: SftpException) {
            if (error.id == ChannelSftp.SSH_FX_NO_SUCH_FILE) null else throw error
        }
    }

    override suspend fun write(name: String, bytes: ByteArray) = withContext(Dispatchers.IO) {
        require(name == "manifest.json" || name.matches(Regex("book-[A-F0-9-]+\\.[a-z0-9]+")))
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
        val pinned = "$knownHost ${pieces[0]} ${pieces[1]}\n"
        val jsch = JSch().apply { setKnownHosts(pinned.byteInputStream()) }
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
