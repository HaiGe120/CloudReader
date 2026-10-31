package io.github.haige120.cloudreader.desktop

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.*
import okhttp3.*
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.RequestBody.Companion.toRequestBody
import java.net.URLEncoder

interface DesktopRemoteStore : io.github.haige120.cloudreader.core.ports.RemoteObjectStore {
    override fun close() = Unit
}
class DesktopVault(private val secrets: DesktopSecrets, private val settings: DesktopSettings) {
    fun get(key: String): String? = if (key.startsWith("sftp.") && key != "sftp.password") settings.get(key).ifBlank { null } else secrets.read(key)
    fun put(key: String, value: String) = secrets.write(key, value)
    fun remove(key: String) = secrets.write(key, "")
}
class DesktopProviderPreferences(private val settings: DesktopSettings) {
    fun get(key: String): String? = settings.get(key).ifBlank { null }
}
private fun requireSafeObject(name: String) {
    require(name == "manifest.json" || name.matches(Regex("book-[A-F0-9-]+\\.[a-z0-9]+"))) { "Unsafe sync object name" }
}

class DesktopDropboxStore(private val vault: DesktopVault, private val preferences: DesktopProviderPreferences, private val http: OkHttpClient = OkHttpClient()) : DesktopRemoteStore {
    override suspend fun read(name: String): ByteArray? = withContext(Dispatchers.IO) {
        requireSafeObject(name)
        val path = "{\"path\":\"/CloudReader/$name\"}"
        val request = Request.Builder().url("https://content.dropboxapi.com/2/files/download").header("Authorization", "Bearer ${accessToken()}")
            .header("Dropbox-API-Arg", path).get().build()
        http.newCall(request).execute().use { response ->
            val bytes = response.body?.byteStream()?.use { boundedBytes(it, if (name == "manifest.json") 16*1024*1024 else 256*1024*1024) } ?: ByteArray(0)
            if (response.code == 409 && bytes.toString(Charsets.UTF_8).contains("path/not_found")) null
            else if (!response.isSuccessful) throw IllegalStateException("Dropbox returned HTTP ${response.code}") else bytes
        }
    }

    override suspend fun write(name: String, bytes: ByteArray) = withContext(Dispatchers.IO) {
        requireSafeObject(name)
        val token = accessToken()
        ensureCloudReaderFolder(token)
        val arg = "{\"path\":\"/CloudReader/$name\",\"mode\":\"overwrite\",\"autorename\":false,\"mute\":true}"
        val request = Request.Builder().url("https://content.dropboxapi.com/2/files/upload").header("Authorization", "Bearer $token")
            .header("Dropbox-API-Arg", arg).header("Content-Type", "application/octet-stream").post(bytes.toRequestBody()).build()
        http.newCall(request).execute().use { if (!it.isSuccessful) throw IllegalStateException("Dropbox upload returned HTTP ${it.code}") }
    }

    private fun ensureCloudReaderFolder(token: String) {
        val body = "{\"path\":\"/CloudReader\",\"autorename\":false}".toRequestBody("application/json".toMediaType())
        val request = Request.Builder().url("https://api.dropboxapi.com/2/files/create_folder_v2")
            .header("Authorization", "Bearer $token").post(body).build()
        http.newCall(request).execute().use { response ->
            if (!response.isSuccessful && response.code != 409) throw IllegalStateException("Dropbox folder setup returned HTTP ${response.code}")
        }
    }

    private suspend fun accessToken(): String {
        val expiresAt = vault.get("dropbox.expiresAt")?.toLongOrNull() ?: 0
        val current = vault.get("dropbox.accessToken")
        if (!current.isNullOrBlank() && expiresAt > System.currentTimeMillis() / 1000L + 60) return current
        val refresh = vault.get("dropbox.refreshToken") ?: throw IllegalStateException("Reconnect Dropbox in Settings.")
        val appKey = preferences.get("dropbox.appKey") ?: throw IllegalStateException("Add the Dropbox app key in Settings.")
        val body = mapOf("grant_type" to "refresh_token", "refresh_token" to refresh, "client_id" to appKey)
            .entries.joinToString("&") { "${enc(it.key)}=${enc(it.value)}" }.toRequestBody("application/x-www-form-urlencoded".toMediaType())
        val request = Request.Builder().url("https://api.dropboxapi.com/oauth2/token").post(body).build()
        return http.newCall(request).execute().use { response ->
            val payload = response.body?.string().orEmpty()
            if (!response.isSuccessful) throw IllegalStateException("Dropbox token refresh returned HTTP ${response.code}")
            val obj = Json.parseToJsonElement(payload).jsonObject
            obj["access_token"]!!.jsonPrimitive.content.also { token ->
                vault.put("dropbox.accessToken", token)
                val expires = obj["expires_in"]?.jsonPrimitive?.content?.toLongOrNull() ?: 14_400L
                vault.put("dropbox.expiresAt", (System.currentTimeMillis() / 1000L + expires).toString())
            }
        }
    }
    private fun enc(value: String) = URLEncoder.encode(value, Charsets.UTF_8.name()).replace("+", "%20")
    override fun close() { http.dispatcher.cancelAll(); http.connectionPool.evictAll(); http.dispatcher.executorService.shutdown() }
}

class DesktopGoogleStore(vault: DesktopVault, private val http: OkHttpClient = OkHttpClient()) : DesktopRemoteStore {
    private val accessToken = vault.get("googleDrive.accessToken")?.takeIf(String::isNotBlank) ?: error("Connect Google Drive in Settings.")
    override suspend fun read(name: String): ByteArray? = withContext(Dispatchers.IO) {
        val id = findId(name) ?: return@withContext null
        val request = Request.Builder().url("https://www.googleapis.com/drive/v3/files/${encPath(id)}?alt=media").header("Authorization", "Bearer ${token()}").get().build()
        http.newCall(request).execute().use { response ->
            if (!response.isSuccessful) throw IllegalStateException("Google Drive returned HTTP ${response.code}")
            response.body?.byteStream()?.use { boundedBytes(it, if (name == "manifest.json") 16*1024*1024 else 256*1024*1024) } ?: ByteArray(0)
        }
    }

    override suspend fun write(name: String, bytes: ByteArray) = withContext(Dispatchers.IO) {
        requireSafeObject(name)
        val id = findId(name)
        val metadata = if (id == null) "{\"name\":\"$name\",\"parents\":[\"appDataFolder\"]}" else "{}"
        val base = if (id == null) "https://www.googleapis.com/upload/drive/v3/files" else "https://www.googleapis.com/upload/drive/v3/files/${encPath(id)}"
        val method = if (id == null) "POST" else "PATCH"
        val start = Request.Builder().url("$base?uploadType=resumable&fields=id").header("Authorization", "Bearer ${token()}")
            .header("X-Upload-Content-Type", "application/octet-stream").header("X-Upload-Content-Length", bytes.size.toString())
            .method(method, metadata.toRequestBody("application/json".toMediaType())).build()
        val location = http.newCall(start).execute().use { response ->
            if (!response.isSuccessful) throw IllegalStateException("Google Drive upload setup returned HTTP ${response.code}")
            response.header("Location") ?: throw IllegalStateException("Google Drive did not return an upload URL.")
        }
        val uploadURI = java.net.URI(location)
        require(uploadURI.scheme == "https" && (uploadURI.host == "googleapis.com" || uploadURI.host?.endsWith(".googleapis.com") == true)) { "Google returned an untrusted upload URL." }
        val upload = Request.Builder().url(location).header("Authorization", "Bearer ${token()}").put(bytes.toRequestBody("application/octet-stream".toMediaType())).build()
        http.newCall(upload).execute().use { if (!it.isSuccessful) throw IllegalStateException("Google Drive upload returned HTTP ${it.code}") }
    }

    private fun token(): String = accessToken

    private fun findId(name: String): String? {
        val query = "name='$name' and trashed=false"
        val url = "https://www.googleapis.com/drive/v3/files?spaces=appDataFolder&q=${URLEncoder.encode(query, Charsets.UTF_8.name())}&fields=files(id,name)&pageSize=100"
        val request = Request.Builder().url(url).header("Authorization", "Bearer ${token()}").get().build()
        return http.newCall(request).execute().use { response ->
            val body = response.body?.string().orEmpty()
            if (!response.isSuccessful) throw IllegalStateException("Google Drive index lookup returned HTTP ${response.code}")
            Json.parseToJsonElement(body).jsonObject["files"]?.jsonArray?.firstOrNull()?.jsonObject?.get("id")?.jsonPrimitive?.content
        }
    }
    private fun encPath(value: String) = URLEncoder.encode(value, Charsets.UTF_8.name())
    override fun close() { http.dispatcher.cancelAll(); http.connectionPool.evictAll(); http.dispatcher.executorService.shutdown() }
}

class DesktopPCloudStore(private val vault: DesktopVault, private val http: OkHttpClient = OkHttpClient()) : DesktopRemoteStore {
    override suspend fun read(name: String): ByteArray? = withContext(Dispatchers.IO) {
        requireSafeObject(name)
        val folderID = cloudFolderID() ?: return@withContext null
        val listing = apiJson("/listfolder?folderid=$folderID")
        val file = listing["metadata"]?.jsonObject?.get("contents")?.jsonArray?.firstOrNull { it.jsonObject["name"]?.jsonPrimitive?.content == name }?.jsonObject
            ?: return@withContext null
        val fileID = file["fileid"]?.jsonPrimitive?.content ?: return@withContext null
        val link = apiJson("/getfilelink?fileid=$fileID")
        val host = link["hosts"]?.jsonArray?.firstOrNull()?.jsonPrimitive?.content ?: ""
        val path = link["path"]?.jsonPrimitive?.content ?: throw IllegalStateException("pCloud did not return a download link.")
        require(host.endsWith(".pcloud.com")) { "pCloud returned an untrusted download host." }
        val request = Request.Builder().url("https://$host$path").get().build()
        http.newCall(request).execute().use { response ->
            if (!response.isSuccessful) throw IllegalStateException("pCloud download returned HTTP ${response.code}")
            response.body?.byteStream()?.use { boundedBytes(it, if (name == "manifest.json") 16*1024*1024 else 256*1024*1024) } ?: ByteArray(0)
        }
    }

    override suspend fun write(name: String, bytes: ByteArray) = withContext(Dispatchers.IO) {
        requireSafeObject(name)
        val folderID = cloudFolderID(create = true) ?: throw IllegalStateException("Could not create the pCloud CloudReader folder.")
        val body = MultipartBody.Builder().setType(MultipartBody.FORM).addFormDataPart("file", name, bytes.toRequestBody("application/octet-stream".toMediaType())).build()
        val url = apiUrl("/uploadfile?folderid=$folderID&filename=${URLEncoder.encode(name, Charsets.UTF_8.name())}")
        val request = Request.Builder().url(url).post(body).build()
        http.newCall(request).execute().use { response ->
            val payload = response.body?.string().orEmpty()
            if (!response.isSuccessful) throw IllegalStateException("pCloud upload returned HTTP ${response.code}")
            val code = Json.parseToJsonElement(payload).jsonObject["result"]?.jsonPrimitive?.content?.toIntOrNull()
            if (code != 0) throw IllegalStateException("pCloud rejected the upload (result $code).")
        }
    }

    private fun cloudFolderID(create: Boolean = false): String? {
        val cached = vault.get("pcloud.cloudReaderFolderID")
        if (!create && !cached.isNullOrBlank()) return cached
        val root = apiJson("/listfolder?folderid=0")
        val contents = root["metadata"]?.jsonObject?.get("contents")?.jsonArray.orEmpty()
        val existing = contents.firstOrNull { it.jsonObject["name"]?.jsonPrimitive?.content == "CloudReader" }?.jsonObject?.get("folderid")?.jsonPrimitive?.content
        val folder = existing ?: if (create) apiJson("/createfolder?name=CloudReader&folderid=0")["metadata"]?.jsonObject?.get("folderid")?.jsonPrimitive?.content else null
        folder?.let { vault.put("pcloud.cloudReaderFolderID", it) }
        return folder
    }

    private fun apiJson(path: String): kotlinx.serialization.json.JsonObject {
        val request = Request.Builder().url(apiUrl(path)).get().build()
        return http.newCall(request).execute().use { response ->
            val body = response.body?.string().orEmpty()
            if (!response.isSuccessful) throw IllegalStateException("pCloud returned HTTP ${response.code}")
            val obj = Json.parseToJsonElement(body).jsonObject
            val result = obj["result"]?.jsonPrimitive?.content?.toIntOrNull()
            if (result != null && result != 0) throw IllegalStateException("pCloud returned result $result")
            obj
        }
    }

    private fun apiUrl(path: String): String {
        val host = vault.get("pcloud.apiHost") ?: "api.pcloud.com"
        require(host in setOf("api.pcloud.com", "eapi.pcloud.com")) { "Unsupported pCloud API region." }
        val token = vault.get("pcloud.accessToken") ?: throw IllegalStateException("Connect pCloud in Settings.")
        val join = if (path.contains('?')) "&" else "?"
        return "https://$host$path${join}access_token=${URLEncoder.encode(token, Charsets.UTF_8.name())}&format=json"
    }
    override fun close() { http.dispatcher.cancelAll(); http.connectionPool.evictAll(); http.dispatcher.executorService.shutdown() }
}
