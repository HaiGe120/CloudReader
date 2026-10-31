package io.github.haige120.cloudreader.sync

import kotlinx.coroutines.test.runTest
import okhttp3.FormBody
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Protocol
import okhttp3.Request
import okhttp3.Response
import okhttp3.ResponseBody.Companion.toResponseBody
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class GoogleOAuthTokenClientTest {
    private val credentials = GoogleOAuthClientCredentials("test-client.apps.googleusercontent.com", "user-secret+&=value")

    @Test fun emptyCredentialsPreserveTheExistingNativeFlow() {
        assertNull(GoogleOAuthConfiguration.credentials(null, null))
        assertNull(GoogleOAuthConfiguration.credentials("  ", "  "))
    }

    @Test fun partialCustomCredentialsAreRejectedWithoutEchoingValues() {
        listOf("private-client" to null, null to "private-secret").forEach { (id, secret) ->
            val error = runCatching { GoogleOAuthConfiguration.credentials(id, secret) }.exceptionOrNull()
            assertTrue(error is IllegalArgumentException)
            assertFalse(error!!.message.orEmpty().contains("private-"))
        }
        val configured = GoogleOAuthConfiguration.credentials("  client-id  ", "  secret  ")!!
        assertEquals("client-id", configured.clientID)
        assertEquals("secret", configured.clientSecret)
    }

    @Test fun nativeServerCodeExchangeUsesConfiguredCredentialsAndBlankRedirect() = runTest {
        var captured: Request? = null
        val client = GoogleOAuthTokenClient(fakeHttp(validTokenResponse) { captured = it })
        val tokens = client.exchangeAuthorizationCode(credentials, "native-code+&=value")

        val request = captured!!
        assertEquals("https://oauth2.googleapis.com/token", request.url.toString())
        assertEquals("POST", request.method)
        assertNull(request.url.query)
        assertEquals(
            mapOf("client_id" to credentials.clientID, "client_secret" to credentials.clientSecret, "grant_type" to "authorization_code", "code" to "native-code+&=value", "redirect_uri" to ""),
            request.formFields(),
        )
        assertEquals("access-secret", tokens.accessToken)
        assertEquals(1_800L, tokens.expiresInSeconds)
        assertEquals("refresh-secret", tokens.refreshToken)
    }

    @Test fun refreshUsesStoredGrantAndCredentialsWithoutAnAuthorizationCode() = runTest {
        var captured: Request? = null
        val client = GoogleOAuthTokenClient(fakeHttp("""{"access_token":"renewed-secret","expires_in":3600,"token_type":"Bearer"}""") { captured = it })
        val tokens = client.refresh(credentials, "stored-refresh+&=value")

        assertEquals(
            mapOf("client_id" to credentials.clientID, "client_secret" to credentials.clientSecret, "grant_type" to "refresh_token", "refresh_token" to "stored-refresh+&=value"),
            captured!!.formFields(),
        )
        assertEquals("renewed-secret", tokens.accessToken)
        assertNull(tokens.refreshToken)
    }

    @Test fun omittedRefreshTokenPreservesOnlyTheGrantForTheSameClient() {
        assertEquals("previous-secret", googleRefreshTokenForClient(null, "previous-secret", "client-A", "client-A", allowPrevious = true))
        assertEquals("rotated-secret", googleRefreshTokenForClient("rotated-secret", "previous-secret", "client-A", "client-B"))
        listOf(null to null, "previous-secret" to "client-A").forEach { (token, clientID) ->
            val error = runCatching { googleRefreshTokenForClient(null, token, clientID, "client-B", allowPrevious = true) }.exceptionOrNull()
            assertTrue(error is IllegalStateException)
            assertTrue(error!!.message.orEmpty().contains("Reconnect Google Drive"))
            assertFalse(error.message.orEmpty().contains("previous-secret"))
        }
    }

    @Test fun anExplicitConnectionCannotReuseAnEarlierAccountsRefreshGrant() {
        val error = runCatching { googleRefreshTokenForClient(null, "earlier-account-secret", "same-client", "same-client") }.exceptionOrNull()
        assertTrue(error is IllegalStateException)
        assertFalse(error!!.message.orEmpty().contains("earlier-account-secret"))
    }

    @Test fun delayedRefreshCannotCommitAfterReconnectChangedTheGrantUnderTheSameClient() {
        val error = runCatching {
            requireCurrentGoogleRefreshGrant("account-A-refresh-secret", "same-client", "account-B-refresh-secret", "same-client")
        }.exceptionOrNull()
        assertTrue(error is IllegalStateException)
        assertTrue(error!!.message.orEmpty().contains("Retry sync"))
        assertFalse(error.message.orEmpty().contains("refresh-secret"))
        requireCurrentGoogleRefreshGrant("account-A-refresh-secret", "same-client", "account-A-refresh-secret", "same-client")
    }

    @Test fun unexpiredCachedAccessIsReusedOnlyWithItsCurrentGrantBinding() {
        val binding = googleOAuthGrantBinding(credentials, "refresh-secret")
        assertEquals("access-secret", cachedGoogleAccessToken("access-secret", 2_000, binding, binding, 1_000))
        assertNull(cachedGoogleAccessToken("access-secret", 2_000, null, binding, 1_000))
        assertNull(cachedGoogleAccessToken("", 2_000, binding, binding, 1_000))
    }

    @Test fun expiredMissingAndNearlyExpiredCacheRequiresRenewal() {
        val binding = googleOAuthGrantBinding(credentials, "refresh-secret")
        listOf(null, 999L, 1_000L, 1_029L).forEach { expiry ->
            assertNull(cachedGoogleAccessToken("access-secret", expiry, binding, binding, 1_000))
        }
        assertEquals("access-secret", cachedGoogleAccessToken("access-secret", 1_030, binding, binding, 1_000))
    }

    @Test fun replacingTheClientSecretClientIDOrRefreshGrantInvalidatesTheCache() {
        val previousBinding = googleOAuthGrantBinding(credentials, "refresh-secret")
        val replacements = listOf(
            googleOAuthGrantBinding(credentials, "different-account-refresh-secret"),
            googleOAuthGrantBinding(GoogleOAuthClientCredentials("different-client", credentials.clientSecret), "refresh-secret"),
            googleOAuthGrantBinding(GoogleOAuthClientCredentials(credentials.clientID, "different-client-secret"), "refresh-secret"),
        )
        replacements.forEach { binding ->
            assertNull(cachedGoogleAccessToken("previous-account-access-secret", 2_000, previousBinding, binding, 1_000))
        }
        assertFalse(previousBinding.contains("refresh-secret"))
        assertFalse(previousBinding.contains(credentials.clientSecret))
    }

    @Test fun clearedOrReboundRefreshGrantsRejectAnOutstandingRefresh() {
        listOf(null to null, "same-refresh-secret" to "different-client").forEach { (token, clientID) ->
            assertTrue(runCatching {
                requireCurrentGoogleRefreshGrant("same-refresh-secret", "original-client", token, clientID)
            }.exceptionOrNull() is IllegalStateException)
        }
    }

    @Test fun aDriveStoreKeepsOneAccountsTokenWhenReconnectedBetweenLookupAndDownload() = runTest {
        val expiry = System.currentTimeMillis() / 1000L + 3_600
        var currentAccount = GoogleDriveAuthorizationSnapshot("account-A-access-secret", expiry)
        var snapshotReads = 0
        val sentAuthorization = mutableListOf<String?>()
        val http = OkHttpClient.Builder().addInterceptor { chain ->
            val request = chain.request()
            sentAuthorization += request.header("Authorization")
            val payload = if (request.url.queryParameter("alt") == "media") "book-bytes" else {
                currentAccount = GoogleDriveAuthorizationSnapshot("account-B-access-secret", expiry)
                """{"files":[{"id":"account-A-file"}]}"""
            }
            Response.Builder().request(request).protocol(Protocol.HTTP_1_1).code(200).message("Test response")
                .body(payload.toResponseBody()).build()
        }.build()
        val store = GoogleDriveStore({ snapshotReads++; currentAccount }, http)
        assertEquals("book-bytes", store.read("manifest.json")!!.toString(Charsets.UTF_8))
        assertEquals(1, snapshotReads)
        assertEquals(listOf("Bearer account-A-access-secret", "Bearer account-A-access-secret"), sentAuthorization)
        assertEquals("account-B-access-secret", currentAccount.token(System.currentTimeMillis() / 1000L))
    }

    @Test fun oauthClientAndRevokedGrantFailuresGiveActionableSafeMessages() = runTest {
        listOf("invalid_client" to "client ID or secret", "invalid_grant" to "expired or was revoked").forEach { (code, expected) ->
            val client = GoogleOAuthTokenClient(fakeHttp("""{"error":"$code","error_description":"echo user-secret+&=value access-secret someone@example.com"}""", 400))
            val error = runCatching { client.exchangeAuthorizationCode(credentials, "native-code-secret") }.exceptionOrNull()
            assertTrue(error is IllegalStateException)
            assertTrue(error!!.message.orEmpty().contains(expected))
            assertTrue(error.message.orEmpty().contains(code))
            assertNoResponseSecrets(error)
        }
    }

    @Test fun unknownOrMalformedErrorBodiesNeverAppearInExceptions() = runTest {
        listOf("""{"error":"access-secret","error_description":"someone@example.com user-secret+&=value"}""", "malformed access-secret someone@example.com user-secret+&=value").forEach { body ->
            val client = GoogleOAuthTokenClient(fakeHttp(body, 500))
            val error = runCatching { client.refresh(credentials, "stored-refresh-secret") }.exceptionOrNull()
            assertTrue(error is IllegalStateException)
            assertNoResponseSecrets(error!!)
            assertTrue(error.message.orEmpty().contains("500"))
        }
    }

    @Test fun successfulButMalformedResponsesCannotBeAcceptedAsCredentials() = runTest {
        val invalidResponses = listOf(
            "access-secret malformed json",
            """{"expires_in":3600}""",
            """{"access_token":"access-secret"}""",
            """{"access_token":"access-secret","expires_in":0}""",
            """{"access_token":"access-secret","expires_in":-1}""",
            """{"access_token":123,"expires_in":3600}""",
            """{"access_token":"access-secret","expires_in":3600,"token_type":"unexpected"}""",
        )
        invalidResponses.forEach { body ->
            val client = GoogleOAuthTokenClient(fakeHttp(body))
            val error = runCatching { client.refresh(credentials, "stored-refresh-secret") }.exceptionOrNull()
            assertTrue("Accepted malformed response", error is IllegalStateException)
            assertNoResponseSecrets(error!!)
        }
    }

    @Test fun aRedirectResponseIsRejectedAsATokenFailure() = runTest {
        var calls = 0
        val http = OkHttpClient.Builder().addInterceptor { chain ->
            calls++
            Response.Builder().request(chain.request()).protocol(Protocol.HTTP_1_1)
                .code(307).message("Temporary Redirect").header("Location", "https://other.example/token")
                .body("".toResponseBody()).build()
        }.build()
        val error = runCatching { GoogleOAuthTokenClient(http).exchangeAuthorizationCode(credentials, "native-code-secret") }.exceptionOrNull()
        assertEquals(1, calls)
        assertTrue(error is IllegalStateException)
        assertTrue(error!!.message.orEmpty().contains("307"))
    }

    @Test fun blankCodesAndRefreshGrantsFailBeforeMakingAnyHttpRequest() = runTest {
        var calls = 0
        val client = GoogleOAuthTokenClient(fakeHttp(validTokenResponse) { calls++ })
        assertTrue(runCatching { client.exchangeAuthorizationCode(credentials, " ") }.exceptionOrNull() is IllegalArgumentException)
        assertTrue(runCatching { client.refresh(credentials, " ") }.exceptionOrNull() is IllegalArgumentException)
        assertEquals(0, calls)
    }

    @Test fun credentialAndTokenStringRepresentationsHideTheirContents() {
        val tokens = GoogleOAuthTokens("access-secret", 3600, "refresh-secret")
        assertFalse(credentials.toString().contains(credentials.clientSecret))
        assertFalse(tokens.toString().contains(tokens.accessToken))
        assertFalse(tokens.toString().contains(tokens.refreshToken!!))
    }

    private fun fakeHttp(body: String, code: Int = 200, observe: (Request) -> Unit = {}): OkHttpClient = OkHttpClient.Builder()
        .addInterceptor { chain ->
            observe(chain.request())
            Response.Builder().request(chain.request()).protocol(Protocol.HTTP_1_1)
                .code(code).message("Test response").body(body.toResponseBody("application/json".toMediaType())).build()
        }.build()

    private fun Request.formFields(): Map<String, String> = (body as FormBody).let { form ->
        (0 until form.size).associate { form.name(it) to form.value(it) }
    }

    private fun assertNoResponseSecrets(error: Throwable) {
        // Coroutine stack-trace recovery can copy a safe exception into its cause chain.
        // Check the whole report, including causes/suppressed errors, for leaked material.
        val report = error.stackTraceToString()
        listOf("user-secret", "access-secret", "someone@example.com", "native-code-secret", "stored-refresh-secret").forEach { secret ->
            assertFalse("Leaked $secret", report.contains(secret))
        }
    }

    private val validTokenResponse = """{"access_token":"access-secret","expires_in":1800,"refresh_token":"refresh-secret","token_type":"Bearer"}"""
}
