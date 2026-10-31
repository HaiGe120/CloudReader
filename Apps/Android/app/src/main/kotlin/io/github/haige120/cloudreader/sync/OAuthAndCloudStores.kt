package io.github.haige120.cloudreader.sync

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.net.Uri
import com.google.android.gms.auth.api.identity.AuthorizationRequest
import com.google.android.gms.auth.api.identity.AuthorizationResult
import com.google.android.gms.auth.api.identity.Identity
import com.google.android.gms.common.api.ApiException
import com.google.android.gms.common.api.Scope
import io.github.haige120.cloudreader.data.CloudReaderPreferences
import io.github.haige120.cloudreader.data.SecureVault
import java.net.URLEncoder
import java.security.MessageDigest
import java.security.SecureRandom
import java.util.Base64
import java.util.concurrent.TimeUnit
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.MultipartBody
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody

object OAuthReturn {
    @Volatile private var callback: ((Result<Uri>) -> Unit)? = null
    @Volatile private var activeState: String? = null

    suspend fun open(context: Context, authorizeUrl: String, expectedState: String): Uri = suspendCancellableCoroutine { continuation ->
        activeState = expectedState
        callback = { result -> if (continuation.isActive) result.fold(continuation::resume, continuation::resumeWithException) }
        continuation.invokeOnCancellation { callback = null; activeState = null }
        try {
            context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(authorizeUrl)).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        } catch (error: Exception) {
            callback = null; activeState = null
            continuation.resumeWithException(IllegalStateException("Could not open the sign-in page.", error))
        }
    }

    fun complete(uri: Uri): Boolean {
        val expected = activeState ?: return false
        val returned = uri.getQueryParameter("state") ?: uri.fragment?.split('&')?.firstOrNull { it.startsWith("state=") }?.substringAfter('=')
        if (returned != expected) {
            callback?.let { onReturn -> callback = null; activeState = null; onReturn(Result.failure(SecurityException("OAuth state did not match."))) }
            return false
        }
        val onReturn = callback ?: return false
        callback = null; activeState = null
        onReturn(Result.success(uri))
        return true
    }
}

class OAuthCallbackActivity : Activity() {
    override fun onCreate(savedInstanceState: android.os.Bundle?) {
        super.onCreate(savedInstanceState)
        intent?.data?.let(OAuthReturn::complete)
        finish()
    }
}

class OAuthConnector(private val context: Context, private val preferences: CloudReaderPreferences, private val vault: SecureVault, private val http: OkHttpClient = OkHttpClient()) {
    suspend fun connectDropbox(): String {
        val appKey = preferences.get("dropbox.appKey")?.trim()?.takeIf(String::isNotBlank)
            ?: throw IllegalStateException("Add the Dropbox app key in Settings.")
        val verifier = randomUrlToken(48)
        val challenge = Base64.getUrlEncoder().withoutPadding().encodeToString(MessageDigest.getInstance("SHA-256").digest(verifier.toByteArray()))
        val state = randomUrlToken(24)
        val redirect = "cloudreader://oauth/dropbox"
        val query = listOf(
            "client_id" to appKey, "response_type" to "code", "redirect_uri" to redirect,
            "code_challenge" to challenge, "code_challenge_method" to "S256",
            "token_access_type" to "offline", "state" to state,
        ).joinToString("&") { "${enc(it.first)}=${enc(it.second)}" }
        val result = OAuthReturn.open(context, "https://www.dropbox.com/oauth2/authorize?$query", state)
        val code = result.getQueryParameter("code") ?: throw IllegalStateException("Dropbox sign-in was cancelled or did not return a code.")
        val response = form("https://api.dropboxapi.com/oauth2/token", mapOf(
            "grant_type" to "authorization_code", "code" to code, "client_id" to appKey,
            "redirect_uri" to redirect, "code_verifier" to verifier,
        ))
        val accessToken = response["access_token"]?.jsonPrimitive?.contentOrNull
            ?: throw IllegalStateException("Dropbox did not return an access token.")
        vault.put("dropbox.accessToken", accessToken)
        response["refresh_token"]?.jsonPrimitive?.contentOrNull?.let { vault.put("dropbox.refreshToken", it) }
        val expiresIn = response["expires_in"]?.jsonPrimitive?.content?.toLongOrNull() ?: 14_400L
        vault.put("dropbox.expiresAt", (System.currentTimeMillis() / 1000L + expiresIn).toString())
        preferences.selectProvider("dropbox", true)
        return response["account_id"]?.jsonPrimitive?.contentOrNull ?: "Dropbox connected"
    }

    suspend fun connectPCloud(): String {
        val appKey = preferences.get("pcloud.appKey")?.trim()?.takeIf(String::isNotBlank)
            ?: throw IllegalStateException("Add the pCloud app key in Settings.")
        val state = randomUrlToken(24)
        val redirect = "cloudreader://oauth/pcloud"
        val url = "https://my.pcloud.com/oauth2/authorize?client_id=${enc(appKey)}&response_type=token&redirect_uri=${enc(redirect)}&state=${enc(state)}"
        val result = OAuthReturn.open(context, url, state)
        val token = result.getQueryParameter("access_token") ?: result.fragment?.split('&')?.firstOrNull { it.startsWith("access_token=") }?.substringAfter('=')?.let(Uri::decode)
            ?: throw IllegalStateException("pCloud sign-in did not return an access token.")
        val host = result.fragment?.split('&')?.firstOrNull { it.startsWith("hostname=") }?.substringAfter('=')?.let(Uri::decode)
            ?: result.getQueryParameter("hostname") ?: "api.pcloud.com"
        require(host in setOf("api.pcloud.com", "eapi.pcloud.com")) { "pCloud returned an unsupported API region." }
        vault.put("pcloud.accessToken", token); vault.put("pcloud.apiHost", host)
        vault.remove("pcloud.cloudReaderFolderID")
        return "pCloud connected"
    }

    suspend fun connectGoogle(accessToken: String, expiresInSeconds: Long = 3_600): String {
        // A custom-client code exchange already saved Google's actual expiry before delivering the token.
        if (vault.get("googleDrive.accessToken") != accessToken || vault.get("googleDrive.expiresAt") == null) {
            saveGoogleToken(accessToken, expiresInSeconds)
        }
        preferences.selectProvider("googleDrive", true)
        return "Google Drive connected"
    }

    private fun saveGoogleToken(accessToken: String, expiresInSeconds: Long = 3_600) {
        require(accessToken.isNotBlank())
        synchronized(GoogleOAuthTokenState.commitLock) {
            vault.put("googleDrive.accessToken", accessToken)
            vault.put("googleDrive.expiresAt", (System.currentTimeMillis() / 1000L + expiresInSeconds).toString())
            vault.remove("googleDrive.accessTokenGrant")
        }
    }

    /** Custom clients renew their stored grant; the default flow renews through Google Play services. */
    suspend fun refreshGoogleToken(): String {
        val credentials = googleClientCredentials()
        if (credentials != null) {
            val (refreshToken, cachedToken) = synchronized(GoogleOAuthTokenState.commitLock) {
                val grant = vault.get("googleDrive.refreshToken")?.takeIf(String::isNotBlank)
                    ?.takeIf { vault.get("googleDrive.refreshTokenClientID") == credentials.clientID }
                    ?: error("Reconnect Google Drive in Settings to approve offline access for this OAuth client.")
                grant to cachedGoogleAccessToken(
                    accessToken = vault.get("googleDrive.accessToken"),
                    expiresAt = vault.get("googleDrive.expiresAt")?.toLongOrNull(),
                    storedGrantBinding = vault.get("googleDrive.accessTokenGrant"),
                    expectedGrantBinding = googleOAuthGrantBinding(credentials, grant),
                    nowEpochSeconds = System.currentTimeMillis() / 1000L,
                )
            }
            if (cachedToken != null) return cachedToken
            val tokens = GoogleOAuthTokenClient(http).refresh(credentials, refreshToken)
            saveGoogleTokens(tokens, credentials, renewalGrant = refreshToken)
            return tokens.accessToken
        }
        val request = AuthorizationRequest.builder()
            .setRequestedScopes(listOf(Scope("https://www.googleapis.com/auth/drive.appdata")))
            .build()
        val result = suspendCancellableCoroutine { continuation ->
            Identity.getAuthorizationClient(context).authorize(request)
                .addOnSuccessListener { authorization ->
                    if (!continuation.isActive) return@addOnSuccessListener
                    if (authorization.hasResolution()) {
                        continuation.resumeWithException(IllegalStateException("Reconnect Google Drive in Settings to approve access."))
                    } else {
                        val token = authorization.accessToken
                        if (token.isNullOrBlank()) continuation.resumeWithException(IllegalStateException("Google did not return an access token."))
                        else continuation.resume(token)
                    }
                }
                .addOnFailureListener { error ->
                    if (continuation.isActive) continuation.resumeWithException(
                        googleAuthorizationFailure(error, GoogleAuthorizationStage.RENEWAL),
                    )
                }
                .addOnCanceledListener {
                    if (continuation.isActive) continuation.resumeWithException(CancellationException("Google Drive authorization was cancelled."))
                }
        }
        // Renewal must not re-select a destination the user disabled during sync.
        saveGoogleToken(result)
        return result
    }

    suspend fun authorizeGoogle(resolve: (android.content.IntentSender) -> Unit, onToken: (String) -> Unit, onError: (Throwable) -> Unit) {
        try {
            val credentials = googleClientCredentials()
            val request = AuthorizationRequest.builder()
                .setRequestedScopes(listOf(Scope("https://www.googleapis.com/auth/drive.appdata")))
                .apply {
                    if (credentials != null) {
                        requestOfflineAccess(credentials.clientID)
                        // A deliberate reconnect must be able to replace a lost or revoked refresh grant.
                        setPrompt(AuthorizationRequest.Prompt.CONSENT)
                    }
                }
                .build()
            val result = suspendCancellableCoroutine<AuthorizationResult> { continuation ->
                Identity.getAuthorizationClient(context).authorize(request)
                    .addOnSuccessListener { if (continuation.isActive) continuation.resume(it) }
                    .addOnFailureListener { if (continuation.isActive) continuation.resumeWithException(it) }
                    .addOnCanceledListener {
                        if (continuation.isActive) continuation.resumeWithException(IllegalStateException("Google Drive connection was cancelled. Tap Connect to try again."))
                    }
            }
            if (result.hasResolution()) {
                val pendingIntent = result.pendingIntent ?: error("Google did not return an authorization screen. Try connecting again.")
                resolve(pendingIntent.intentSender)
            } else onToken(googleAccessToken(result, credentials))
        } catch (error: CancellationException) {
            throw error
        } catch (error: Exception) {
            onError(googleAuthorizationFailure(error, GoogleAuthorizationStage.REQUEST))
        }
    }

    suspend fun finishGoogle(data: Intent?): String = try {
        val result = Identity.getAuthorizationClient(context).getAuthorizationResultFromIntent(data)
        googleAccessToken(result, googleClientCredentials())
    } catch (error: CancellationException) {
        throw error
    } catch (error: Exception) {
        throw googleAuthorizationFailure(error, GoogleAuthorizationStage.CALLBACK)
    }

    private suspend fun googleClientCredentials(): GoogleOAuthClientCredentials? = GoogleOAuthConfiguration.credentials(
        preferences.get("googleDrive.clientID"), vault.get("googleDrive.clientSecret"),
    )

    private suspend fun googleAccessToken(result: AuthorizationResult, credentials: GoogleOAuthClientCredentials?): String {
        if (credentials != null) {
            val code = result.serverAuthCode?.takeIf(String::isNotBlank)
                ?: error("Google did not return an authorization code for the configured Web client. Check the Android and Web OAuth clients are in the same project, then reconnect Google Drive.")
            val tokens = GoogleOAuthTokenClient(http).exchangeAuthorizationCode(credentials, code)
            saveGoogleTokens(tokens, credentials)
            return tokens.accessToken
        }
        check(result.serverAuthCode.isNullOrBlank()) { "Google OAuth settings changed during authorization. Connect Google Drive again." }
        return result.accessToken?.takeIf(String::isNotBlank)
            ?: error("Google returned an authorization result without an access token. Tap Connect and approve access to CloudReader's app data.")
    }

    private suspend fun saveGoogleTokens(tokens: GoogleOAuthTokens, credentials: GoogleOAuthClientCredentials, renewalGrant: String? = null) {
        val current = googleClientCredentials()
        check(current != null && current.clientID == credentials.clientID && current.clientSecret == credentials.clientSecret) {
            "Google OAuth settings changed during authorization. Connect Google Drive again."
        }
        synchronized(GoogleOAuthTokenState.commitLock) {
            val previousToken = vault.get("googleDrive.refreshToken")
            val previousClientID = vault.get("googleDrive.refreshTokenClientID")
            if (renewalGrant != null) {
                requireCurrentGoogleRefreshGrant(renewalGrant, credentials.clientID, previousToken, previousClientID)
            }
            val refreshToken = googleRefreshTokenForClient(
                incoming = tokens.refreshToken,
                previous = previousToken,
                previousClientID = previousClientID,
                currentClientID = credentials.clientID,
                // An explicit account selection may have changed users; only renewal can retain an old grant.
                allowPrevious = renewalGrant != null,
            )
            if (tokens.refreshToken != null) {
                vault.put("googleDrive.refreshToken", refreshToken)
                vault.put("googleDrive.refreshTokenClientID", credentials.clientID)
            }
            saveGoogleToken(tokens.accessToken, tokens.expiresInSeconds)
            vault.put("googleDrive.accessTokenGrant", googleOAuthGrantBinding(credentials, refreshToken))
        }
    }

    private fun googleAuthorizationFailure(error: Exception, stage: GoogleAuthorizationStage): IllegalStateException {
        val code = (error as? ApiException)?.statusCode
        return IllegalStateException(
            GoogleAuthorizationDiagnostics.message(
                code = code,
                providerMessage = error.message,
                stage = stage,
                registration = if (code in listOf(8, 10, 12500)) googleOAuthRegistration() else null,
            ),
            error,
        )
    }

    internal fun googleOAuthRegistration(): String {
        val sha1 = runCatching {
            val info = context.packageManager.getPackageInfo(context.packageName, android.content.pm.PackageManager.GET_SIGNING_CERTIFICATES)
            info.signingInfo?.apkContentsSigners?.joinToString("\n") { signature ->
                MessageDigest.getInstance("SHA-1").digest(signature.toByteArray()).joinToString(":") { "%02X".format(it) }
            }
        }.getOrNull() ?: "Signing certificate unavailable"
        return "Package: ${context.packageName}\nSHA-1: $sha1"
    }

    private suspend fun form(url: String, values: Map<String, String>): kotlinx.serialization.json.JsonObject = withContext(Dispatchers.IO) {
        val body = values.entries.joinToString("&") { "${enc(it.key)}=${enc(it.value)}" }.toRequestBody("application/x-www-form-urlencoded".toMediaType())
        val request = Request.Builder().url(url).post(body).build()
        http.newCall(request).execute().use { response ->
            val bytes = response.body?.string().orEmpty()
            if (!response.isSuccessful) throw IllegalStateException("OAuth token exchange returned HTTP ${response.code}: ${bytes.take(300)}")
            Json.parseToJsonElement(bytes).jsonObject
        }
    }

    private fun enc(value: String): String = URLEncoder.encode(value, Charsets.UTF_8.name()).replace("+", "%20")
    private fun randomUrlToken(length: Int): String = ByteArray(length).also(SecureRandom()::nextBytes).let { Base64.getUrlEncoder().withoutPadding().encodeToString(it) }

}

class DropboxStore(private val vault: SecureVault, private val preferences: CloudReaderPreferences, private val http: OkHttpClient = OkHttpClient()) : RemoteBookStore {
    override suspend fun read(name: String): ByteArray? = withContext(Dispatchers.IO) {
        requireSafeObject(name)
        val path = "{\"path\":\"/CloudReader/$name\"}"
        val request = Request.Builder().url("https://content.dropboxapi.com/2/files/download").header("Authorization", "Bearer ${accessToken()}")
            .header("Dropbox-API-Arg", path).get().build()
        http.newCall(request).execute().use { response ->
            val bytes = response.body?.bytes() ?: ByteArray(0)
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
}

class GoogleDriveStore internal constructor(
    tokenSnapshot: () -> GoogleDriveAuthorizationSnapshot,
    private val http: OkHttpClient = OkHttpClient(),
) : RemoteBookStore {
    // Keep one account's authorization for the entire sync pass, even if Settings reconnects meanwhile.
    private val authorization = synchronized(GoogleOAuthTokenState.commitLock) { tokenSnapshot() }

    constructor(vault: SecureVault, http: OkHttpClient = OkHttpClient()) : this(
        {
            GoogleDriveAuthorizationSnapshot(
                vault.get("googleDrive.accessToken"),
                vault.get("googleDrive.expiresAt")?.toLongOrNull() ?: 0,
            )
        },
        http,
    )
    override suspend fun read(name: String): ByteArray? = withContext(Dispatchers.IO) {
        val id = findId(name) ?: return@withContext null
        val request = Request.Builder().url("https://www.googleapis.com/drive/v3/files/${encPath(id)}?alt=media").header("Authorization", "Bearer ${token()}").get().build()
        http.newCall(request).execute().use { response ->
            if (!response.isSuccessful) throw IllegalStateException("Google Drive returned HTTP ${response.code}")
            response.body?.bytes() ?: ByteArray(0)
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
        val upload = Request.Builder().url(location).header("Authorization", "Bearer ${token()}").put(bytes.toRequestBody("application/octet-stream".toMediaType())).build()
        http.newCall(upload).execute().use { if (!it.isSuccessful) throw IllegalStateException("Google Drive upload returned HTTP ${it.code}") }
    }

    private fun token(): String = authorization.token(System.currentTimeMillis() / 1000L)

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
}

class PCloudStore(private val vault: SecureVault, private val http: OkHttpClient = OkHttpClient()) : RemoteBookStore {
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
            response.body?.bytes() ?: ByteArray(0)
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
}
