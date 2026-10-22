package io.github.haige120.cloudreader.sync

import java.io.IOException
import java.security.MessageDigest
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import okhttp3.FormBody
import okhttp3.OkHttpClient
import okhttp3.Request

internal class GoogleOAuthClientCredentials(val clientID: String, val clientSecret: String) {
    override fun toString(): String = "GoogleOAuthClientCredentials([redacted])"
}

internal class GoogleOAuthTokens(val accessToken: String, val expiresInSeconds: Long, val refreshToken: String?) {
    override fun toString(): String = "GoogleOAuthTokens([redacted])"
}

/** Shared by connector instances so a renewal cannot commit across an interactive reconnect. */
internal object GoogleOAuthTokenState {
    val commitLock = Any()
}

internal fun googleOAuthGrantBinding(credentials: GoogleOAuthClientCredentials, refreshToken: String): String =
    MessageDigest.getInstance("SHA-256")
        .digest("${credentials.clientID}\u0000${credentials.clientSecret}\u0000$refreshToken".toByteArray(Charsets.UTF_8))
        .joinToString("") { "%02x".format(it) }

internal fun cachedGoogleAccessToken(
    accessToken: String?,
    expiresAt: Long?,
    storedGrantBinding: String?,
    expectedGrantBinding: String,
    nowEpochSeconds: Long,
): String? = accessToken?.takeIf {
    it.isNotBlank() && expiresAt != null && expiresAt >= nowEpochSeconds + 30 && storedGrantBinding == expectedGrantBinding
}

internal fun requireCurrentGoogleRefreshGrant(
    requestedToken: String,
    requestedClientID: String,
    currentToken: String?,
    currentClientID: String?,
) {
    check(requestedToken == currentToken && requestedClientID == currentClientID) {
        "The Google account changed while authorization was being renewed. Retry sync with the current connection."
    }
}

internal class GoogleDriveAuthorizationSnapshot(private val accessToken: String?, private val expiresAt: Long) {
    fun token(nowEpochSeconds: Long): String {
        check(expiresAt >= nowEpochSeconds + 30) { "Reconnect Google Drive in Settings to refresh authorization." }
        return accessToken?.takeIf(String::isNotBlank) ?: error("Connect Google Drive in Settings.")
    }

    override fun toString(): String = "GoogleDriveAuthorizationSnapshot([redacted])"
}

internal object GoogleOAuthConfiguration {
    fun credentials(clientID: String?, clientSecret: String?): GoogleOAuthClientCredentials? {
        val id = clientID?.trim().orEmpty()
        val secret = clientSecret?.trim().orEmpty()
        if (id.isEmpty() && secret.isEmpty()) return null
        require(id.isNotEmpty()) { "Add the Google OAuth Web application client ID in Settings." }
        require(secret.isNotEmpty()) { "Add the matching Google OAuth client secret in Settings." }
        return GoogleOAuthClientCredentials(id, secret)
    }
}

internal fun googleRefreshTokenForClient(
    incoming: String?,
    previous: String?,
    previousClientID: String?,
    currentClientID: String,
    allowPrevious: Boolean = false,
): String = incoming?.takeIf(String::isNotBlank)
    ?: previous?.takeIf { allowPrevious && it.isNotBlank() && previousClientID == currentClientID }
    ?: error("Google did not return offline access for this OAuth client. Reconnect Google Drive and approve access again.")

/** Exchanges native Google server auth codes; credentials and response bodies never enter diagnostics. */
internal class GoogleOAuthTokenClient(http: OkHttpClient) {
    // Never forward the client secret or refresh token to a redirected endpoint.
    private val http = http.newBuilder().followRedirects(false).followSslRedirects(false).build()

    suspend fun exchangeAuthorizationCode(credentials: GoogleOAuthClientCredentials, code: String): GoogleOAuthTokens {
        require(code.isNotBlank()) { "Google did not return an authorization code. Connect Google Drive again." }
        return request(
            credentials,
            mapOf("grant_type" to "authorization_code", "code" to code, "redirect_uri" to ""),
        )
    }

    suspend fun refresh(credentials: GoogleOAuthClientCredentials, refreshToken: String): GoogleOAuthTokens {
        require(refreshToken.isNotBlank()) { "Reconnect Google Drive in Settings to approve offline access." }
        return request(credentials, mapOf("grant_type" to "refresh_token", "refresh_token" to refreshToken))
    }

    private suspend fun request(credentials: GoogleOAuthClientCredentials, values: Map<String, String>): GoogleOAuthTokens = withContext(Dispatchers.IO) {
        val body = FormBody.Builder()
            .add("client_id", credentials.clientID)
            .add("client_secret", credentials.clientSecret)
            .apply { values.forEach { (name, value) -> add(name, value) } }
            .build()
        val request = Request.Builder().url("https://oauth2.googleapis.com/token").post(body).build()
        try {
            http.newCall(request).execute().use { response ->
                val json = runCatching { Json.parseToJsonElement(response.body?.string().orEmpty()) as? JsonObject }.getOrNull()
                val errorCode = json?.string("error")
                if (!response.isSuccessful || errorCode != null) throw tokenFailure(response.code, errorCode)
                checkNotNull(json) { "Google returned an unreadable token response. Connect Google Drive again." }
                val token = json.string("access_token")?.takeIf(String::isNotBlank)
                    ?: error("Google returned a token response without an access token. Connect Google Drive again.")
                val expiry = (json["expires_in"] as? JsonPrimitive)?.contentOrNull?.toLongOrNull()
                    ?.takeIf { it in 1L..31_536_000L }
                    ?: error("Google returned a token response without a valid expiry. Connect Google Drive again.")
                val tokenType = json.string("token_type")
                check(tokenType == null || tokenType.equals("Bearer", ignoreCase = true)) {
                    "Google returned an unsupported token type. Connect Google Drive again."
                }
                GoogleOAuthTokens(token, expiry, json.string("refresh_token")?.takeIf(String::isNotBlank))
            }
        } catch (_: IOException) {
            // Network errors and malformed response bodies can contain request/response material.
            throw IllegalStateException("Could not reach Google's token service. Check the network and try again.")
        }
    }

    private fun JsonObject.string(name: String): String? = (this[name] as? JsonPrimitive)?.takeIf { it.isString }?.contentOrNull

    private fun tokenFailure(status: Int, errorCode: String?): IllegalStateException {
        val explanation = when (errorCode) {
            "invalid_client", "unauthorized_client" -> "Google could not accept this OAuth Web client ID or secret. Check the matching credentials and project in Settings."
            "invalid_grant" -> "Google authorization expired or was revoked. Reconnect Google Drive in Settings."
            "invalid_scope", "access_denied" -> "Google did not grant the required Drive access. Reconnect Google Drive and approve access."
            "temporarily_unavailable", "server_error" -> "Google's token service is temporarily unavailable. Try connecting again."
            else -> "Google could not exchange the authorization token. Check the OAuth settings and reconnect Google Drive."
        }
        // Do not expose error_description or arbitrary error values: Google may echo credentials.
        val knownCode = errorCode?.takeIf {
            it in setOf("invalid_client", "unauthorized_client", "invalid_grant", "invalid_scope", "access_denied", "temporarily_unavailable", "server_error", "invalid_request", "unsupported_grant_type")
        }
        return IllegalStateException("$explanation\nGoogle token service HTTP status: $status${knownCode?.let { " ($it)" }.orEmpty()}")
    }
}
