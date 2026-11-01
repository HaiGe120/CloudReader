package io.github.haige120.cloudreader.desktop

import java.io.ByteArrayInputStream
import java.io.IOException
import java.net.URLDecoder
import java.nio.file.Files
import java.nio.file.Path
import java.util.Properties
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import okhttp3.OkHttpClient
import okhttp3.Protocol
import okhttp3.Request
import okhttp3.Response
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.ResponseBody.Companion.toResponseBody
import okio.Buffer
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class DesktopOAuthTest {
    @Rule @JvmField val temporary = TemporaryFolder()

    @Test fun reconnectWithoutRefreshTokenClearsPreviousGrantAndStaysDisabled() {
        for(custom in listOf(false,true)){
            val f=fixture(mapOf(CLIENT_ID to CUSTOM_ID,MODE to custom.toString()))
            val others=f.otherProviders()
            val client=if(custom)DesktopGoogleClient(CUSTOM_ID,CUSTOM_SECRET)else DesktopGoogleClient(BUNDLED_ID,BUNDLED_SECRET)
            val tokens=Json.parseToJsonElement("""{"access_token":"fixture-account-b-access","expires_in":3600}""") as JsonObject
            val error=failure{f.oauth.saveGoogleTokens(DesktopOAuth.GoogleConnection(client,custom),tokens,enable=true)}
            assertTrue(error.message.orEmpty().contains("did not return offline access"))
            assertSanitized(error)
            f.assertInvalidated()
            assertEquals(CUSTOM_SECRET,f.secrets.read(CLIENT_SECRET))
            assertEquals(others,f.otherProviders())
        }
    }

    @Test fun reconnectWithNewRefreshGrantEnablesOnlyTheNewAccountTokens() {
        val f=fixture(mapOf(ENABLED to "false"))
        val others=f.otherProviders()
        val tokens=Json.parseToJsonElement("""{"access_token":"fixture-account-b-access","refresh_token":"fixture-account-b-refresh","expires_in":3600}""") as JsonObject
        f.oauth.saveGoogleTokens(DesktopOAuth.GoogleConnection(DesktopGoogleClient(BUNDLED_ID,BUNDLED_SECRET),false),tokens,enable=true)
        assertEquals("fixture-account-b-access",f.secrets.read("googleDrive.accessToken"))
        assertEquals("fixture-account-b-refresh",f.secrets.read("googleDrive.refreshToken"))
        assertEquals("true",f.settings.get(ENABLED))
        assertEquals(others,f.otherProviders())
    }

    @Test fun bundledPropertiesUseExactKeysTrimValuesAndRedactBothFields() {
        val input = ByteArrayInputStream("clientID=  $BUNDLED_ID  \nclientSecret=  $BUNDLED_SECRET  \n".toByteArray())
        val client = DesktopGoogleClient.fromProperties(input)
        assertEquals(BUNDLED_ID, client.clientId)
        assertEquals(BUNDLED_SECRET, client.clientSecret)
        assertFalse(client.toString().contains(BUNDLED_ID))
        assertFalse(client.toString().contains(BUNDLED_SECRET))
        assertTrue(client.toString().contains("redacted"))
    }

    @Test fun absentEmptyAndMalformedBundledPropertiesStayUnconfigured() {
        for (input in listOf(null, "", "client_id=$BUNDLED_ID", "clientID=\\uZZZZ")) {
            val client = DesktopGoogleClient.fromProperties(input?.let { ByteArrayInputStream(it.toByteArray()) })
            assertEquals("", client.clientId)
            assertEquals("", client.clientSecret)
        }
    }

    @Test fun absentModeUsesBundledWhenNoSavedClientAndDoesNotMutateAnything() {
        val f = fixture()
        val before = f.diskState()
        assertFalse(f.oauth.useCustomGoogleCredentials())
        assertEquals(before, f.diskState())
    }

    @Test fun absentModePreservesLegacyCustomClientAndGrant() {
        val f = fixture(mapOf(CLIENT_ID to "  $CUSTOM_ID  "))
        val before = f.diskState()
        assertTrue(f.oauth.useCustomGoogleCredentials())
        assertEquals(before, f.diskState())
    }

    @Test fun explicitModesOverrideInferenceEvenWithSavedAdvancedCredentials() {
        val f = fixture(mapOf(CLIENT_ID to CUSTOM_ID, MODE to "false"))
        assertFalse(f.oauth.useCustomGoogleCredentials())
        f.settings.save(mapOf(MODE to "true", CLIENT_ID to ""))
        assertTrue(f.oauth.useCustomGoogleCredentials())
    }

    @Test fun persistingSameInferredModeRetainsTokensAndEnabledState() {
        for (client in listOf("", CUSTOM_ID)) {
            val f = fixture(mapOf(CLIENT_ID to client))
            val tokens = f.tokens()
            val others = f.otherProviders()
            val custom = client.isNotBlank()
            assertFalse(f.oauth.setGoogleConnectionMode(custom))
            assertEquals(custom.toString(), f.settings.get(MODE))
            assertEquals(custom.toString(), readProperties(f.settingsFile)[MODE])
            assertEquals(tokens, f.tokens())
            assertEquals("true", f.settings.get(ENABLED))
            assertEquals(CUSTOM_SECRET, f.secrets.read(CLIENT_SECRET))
            assertEquals(others, f.otherProviders())
            assertFalse(f.oauth.setGoogleConnectionMode(custom))
            assertEquals(tokens, f.tokens())
        }
    }

    @Test fun intentionalModeSwitchesInvalidateOnlyGoogleAndRetainAdvancedCredentials() {
        val f = fixture(mapOf(CLIENT_ID to CUSTOM_ID, MODE to "false"))
        val others = f.otherProviders()
        for (custom in listOf(true, false)) {
            assertTrue(f.oauth.setGoogleConnectionMode(custom))
            assertEquals(custom, f.oauth.useCustomGoogleCredentials())
            f.assertInvalidated()
            assertEquals(CUSTOM_ID, f.settings.get(CLIENT_ID))
            assertEquals(CUSTOM_SECRET, f.secrets.read(CLIENT_SECRET))
            assertEquals(others, f.otherProviders())
            f.seedTokens()
            f.settings.save(mapOf(ENABLED to "true"))
            val tokens = f.tokens()
            assertFalse(f.oauth.setGoogleConnectionMode(custom))
            assertEquals(tokens, f.tokens())
            assertEquals("true", f.settings.get(ENABLED))
        }
    }

    @Test fun unchangedCustomCredentialsAndBlankSecretRetainGrantWithoutWrites() {
        val f = fixture(mapOf(CLIENT_ID to CUSTOM_ID))
        val before = f.diskState()
        assertFalse(f.oauth.saveGoogleCredentials("  $CUSTOM_ID  ", " \t"))
        assertFalse(f.oauth.saveGoogleCredentials(CUSTOM_ID, " $CUSTOM_SECRET "))
        assertEquals(before, f.diskState())
        assertTrue(f.oauth.useCustomGoogleCredentials())
        assertEquals("true", f.settings.get(ENABLED))
    }

    @Test fun trimmingLegacyClientFormattingDoesNotInvalidateItsGrant() {
        val f = fixture(mapOf(CLIENT_ID to " $CUSTOM_ID "))
        val tokens = f.tokens()
        assertFalse(f.oauth.saveGoogleCredentials(CUSTOM_ID, ""))
        assertEquals(CUSTOM_ID, f.settings.get(CLIENT_ID))
        assertEquals(tokens, f.tokens())
        assertEquals("true", f.settings.get(ENABLED))
    }

    @Test fun differentClientWithBlankSecretFailsWithoutReusingSavedSecret() {
        val f = fixture(mapOf(CLIENT_ID to CUSTOM_ID))
        val before = f.diskState()
        val error = failure { f.oauth.saveGoogleCredentials(OTHER_ID, " ") }
        assertTrue(error is IllegalArgumentException)
        assertTrue(error.message.orEmpty().contains("matching secret"))
        assertSanitized(error)
        assertEquals(before, f.diskState())
    }

    @Test fun firstCustomClientAlsoRequiresExplicitSecret() {
        val f = fixture(mapOf(MODE to "true"))
        val before = f.diskState()
        failure { f.oauth.saveGoogleCredentials(CUSTOM_ID, "") }
        assertEquals(before, f.diskState())
    }

    @Test fun changedClientOrSecretInvalidatesOnlyGoogleAndPersistsTrimmedPair() {
        for ((client, secret) in listOf(OTHER_ID to "fixture-other-secret", CUSTOM_ID to "fixture-rotated-secret")) {
            val f = fixture(mapOf(CLIENT_ID to CUSTOM_ID))
            val others = f.otherProviders()
            assertTrue(f.oauth.saveGoogleCredentials(" $client ", " $secret "))
            assertEquals(client, f.settings.get(CLIENT_ID))
            assertEquals(client, DesktopSettings(f.settingsFile).get(CLIENT_ID))
            assertEquals(secret, f.secrets.read(CLIENT_SECRET))
            assertEquals(secret, readProperties(f.secretFile)["CloudReader|$CLIENT_SECRET"])
            assertTrue(f.oauth.useCustomGoogleCredentials())
            f.assertInvalidated()
            assertEquals(others, f.otherProviders())
        }
    }

    @Test fun clearingBothFieldsResetsCustomCredentialsWithoutFallingIntoBundledMode() {
        val f = fixture(mapOf(CLIENT_ID to CUSTOM_ID)) // Legacy inferred mode.
        val others = f.otherProviders()
        assertTrue(f.oauth.saveGoogleCredentials(" ", "\t"))
        assertEquals("", f.settings.get(CLIENT_ID))
        assertEquals("", f.secrets.read(CLIENT_SECRET))
        assertTrue(f.oauth.useCustomGoogleCredentials())
        assertEquals("true", f.settings.get(MODE))
        f.assertInvalidated()
        assertEquals(others, f.otherProviders())
        assertFalse(f.oauth.saveGoogleCredentials("", ""))
    }

    @Test fun invalidCustomInputsAreRejectedWithoutLeakingValuesOrMutatingState() {
        val f = fixture(mapOf(CLIENT_ID to CUSTOM_ID))
        val before = f.diskState()
        for ((client, secret) in listOf(
            "" to PRIVATE, PRIVATE to PRIVATE, ".apps.googleusercontent.com" to PRIVATE,
            "fixture.apps.googleusercontent.com.invalid" to PRIVATE, "fixture bad.apps.googleusercontent.com" to PRIVATE,
        )) {
            assertSanitized(failure { f.oauth.saveGoogleCredentials(client, secret) })
            assertEquals(before, f.diskState())
        }
    }

    @Test fun customSavingCannotImplicitlySwitchBundledMode() {
        val f = fixture(mapOf(CLIENT_ID to CUSTOM_ID, MODE to "false"))
        val before = f.diskState()
        failure { f.oauth.saveGoogleCredentials(OTHER_ID, PRIVATE) }
        assertFalse(f.oauth.useCustomGoogleCredentials())
        assertEquals(before, f.diskState())
    }

    @Test fun preferenceSaveFailureRestoresClientSecretTokensAndInMemorySettings() {
        val f = fixture(mapOf(CLIENT_ID to CUSTOM_ID))
        val before = f.diskState()
        val backup = blockFile(f.settingsFile)
        val error = failure { f.oauth.saveGoogleCredentials(OTHER_ID, PRIVATE) }
        assertSanitized(error)
        assertEquals(CUSTOM_ID, f.settings.get(CLIENT_ID))
        assertEquals(CUSTOM_SECRET, f.secrets.read(CLIENT_SECRET))
        assertEquals("true", f.settings.get(ENABLED))
        assertTrue(f.oauth.useCustomGoogleCredentials())
        assertEquals(SEEDED_TOKENS, f.tokens())
        restoreFile(f.settingsFile, backup)
        assertEquals(before, f.diskState())
    }

    @Test fun modePreferenceFailureRestoresEffectiveModeWithoutInvalidatingTokens() {
        val f = fixture(mapOf(CLIENT_ID to CUSTOM_ID, MODE to "false"))
        val before = f.diskState()
        val backup = blockFile(f.settingsFile)
        assertSanitized(failure { f.oauth.setGoogleConnectionMode(true) })
        assertFalse(f.oauth.useCustomGoogleCredentials())
        assertEquals("true", f.settings.get(ENABLED))
        assertEquals(SEEDED_TOKENS, f.tokens())
        restoreFile(f.settingsFile, backup)
        assertEquals(before, f.diskState())
    }

    @Test fun secretWriteFailureRestoresSessionValuesAndLeavesGrantAndPreferences() {
        val f = fixture(mapOf(CLIENT_ID to CUSTOM_ID))
        val before = f.diskState()
        val backup = blockFile(f.secretFile)
        assertSanitized(failure { f.oauth.saveGoogleCredentials(OTHER_ID, PRIVATE) })
        assertEquals(CUSTOM_SECRET, f.secrets.read(CLIENT_SECRET))
        assertEquals(CUSTOM_ID, f.settings.get(CLIENT_ID))
        assertEquals(SEEDED_TOKENS, f.tokens())
        restoreFile(f.secretFile, backup)
        // A legacy absent mode can be restored as an empty value by DesktopSettings' API.
        assertEquals(before.first, f.diskState().first.filterValues { it.isNotEmpty() })
        assertEquals(before.second, f.diskState().second)
    }

    @Test fun missingBundledIdFailsBeforeBrowserOrHttpWithMaintainerMessage() {
        val f = fixture(defaults = DesktopGoogleClient())
        f.secrets.write("googleDrive.expiresAt", "9999999999")
        val before = f.diskState()
        for (operation in listOf<() -> Unit>({ f.oauth.connect("googleDrive") }, { f.oauth.refreshGoogle() })) {
            val error = failure(operation)
            assertEquals("Google sign-in is not configured in this build. Contact the app maintainer.", error.message)
            assertEquals(before, f.diskState())
        }
    }

    @Test fun malformedBundledIdHasShortMaintainerMessageAndIgnoresSavedCustomId() {
        val f = fixture(mapOf(CLIENT_ID to CUSTOM_ID, MODE to "false"), defaults = DesktopGoogleClient(PRIVATE, PRIVATE))
        val error = failure { f.oauth.refreshGoogle() }
        assertEquals("Google sign-in is misconfigured in this build. Contact the app maintainer.", error.message)
        assertSanitized(error)
    }

    @Test fun selectedCustomModeWithEmptyClientNeverFallsBackToBundledClient() {
        val f = fixture(mapOf(MODE to "true"))
        val before = f.diskState()
        for (operation in listOf<() -> Unit>({ f.oauth.connect("googleDrive") }, { f.oauth.refreshGoogle() })) {
            val error = failure(operation)
            assertTrue(error.message.orEmpty().contains("advanced settings"))
            assertSanitized(error)
            assertEquals(before, f.diskState())
        }
    }

    @Test fun bundledRefreshUsesOnlyBundledPairAndNeverCopiesItIntoAdvancedSettings() {
        var calls = 0
        val f = fixture(mapOf(CLIENT_ID to "fixture-invalid-saved-id", MODE to "false", ENABLED to "false"),
            http = responseClient { request ->
                calls++
                val form = requestForm(request)
                assertEquals(BUNDLED_ID, form["client_id"])
                assertEquals(BUNDLED_SECRET, form["client_secret"])
                assertEquals(SEEDED_TOKENS["googleDrive.refreshToken"], form["refresh_token"])
                assertEquals("refresh_token", form["grant_type"])
            })
        val others = f.otherProviders()
        f.oauth.refreshGoogle()
        assertEquals(1, calls)
        assertEquals("fixture-new-access", f.secrets.read("googleDrive.accessToken"))
        assertEquals(SEEDED_TOKENS["googleDrive.refreshToken"], f.secrets.read("googleDrive.refreshToken"))
        assertTrue(f.secrets.read("googleDrive.expiresAt")!!.toLong() > System.currentTimeMillis() / 1000)
        assertEquals("fixture-invalid-saved-id", f.settings.get(CLIENT_ID))
        assertEquals(CUSTOM_SECRET, f.secrets.read(CLIENT_SECRET))
        assertEquals("false", f.settings.get(ENABLED)) // Refresh never enables a destination.
        assertEquals(others, f.otherProviders())
    }

    @Test fun legacyAndExplicitCustomRefreshUseCustomPairEvenWithoutBundledConfiguration() {
        for (mode in listOf(null, "true")) {
            var calls = 0
            val values = mutableMapOf(CLIENT_ID to CUSTOM_ID)
            if (mode != null) values[MODE] = mode
            val f = fixture(values, defaults = DesktopGoogleClient(), http = responseClient { request ->
                calls++
                assertEquals(CUSTOM_ID, requestForm(request)["client_id"])
                assertEquals(CUSTOM_SECRET, requestForm(request)["client_secret"])
            })
            f.oauth.refreshGoogle()
            assertEquals(1, calls)
        }
    }

    @Test fun bundledInputsAreTrimmedAndBlankPublicClientSecretIsOmitted() {
        val f = fixture(defaults = DesktopGoogleClient(" $BUNDLED_ID ", " "), http = responseClient { request ->
            val form = requestForm(request)
            assertEquals(BUNDLED_ID, form["client_id"])
            assertFalse(form.containsKey("client_secret"))
        })
        f.oauth.refreshGoogle()
    }

    @Test fun unexpiredGrantIsRetainedWithoutAnyHttpRequest() {
        for (mode in listOf("false", "true")) {
            val f = fixture(mapOf(CLIENT_ID to CUSTOM_ID, MODE to mode))
            f.secrets.write("googleDrive.expiresAt", "9999999999")
            val before = f.diskState()
            f.oauth.refreshGoogle()
            assertEquals(before, f.diskState())
        }
    }

    @Test fun missingRefreshTokenRequiresReconnectWithoutEnablingGoogle() {
        val f = fixture(mapOf(ENABLED to "false"))
        f.secrets.write("googleDrive.refreshToken", "")
        val before = f.diskState()
        assertTrue(failure { f.oauth.refreshGoogle() }.message.orEmpty().contains("Reconnect"))
        assertEquals(before, f.diskState())
    }

    @Test fun successfulRefreshCanRotateRefreshTokenInExistingNativeKeys() {
        val f = fixture(http = responseClient(body = """{"access_token":"fixture-new-access","refresh_token":"fixture-new-refresh","expires_in":3600}"""))
        f.oauth.refreshGoogle()
        assertEquals("fixture-new-refresh", f.secrets.read("googleDrive.refreshToken"))
        assertEquals("fixture-new-refresh", readProperties(f.secretFile)["CloudReader|googleDrive.refreshToken"])
    }

    @Test fun knownGoogleHttpErrorsGiveModeAppropriateRecoveryWithoutProviderDetails() {
        for (custom in listOf(false, true)) for (code in listOf("invalid_client", "invalid_grant", "access_denied")) {
            val f = fixture(mapOf(CLIENT_ID to CUSTOM_ID, MODE to custom.toString(), ENABLED to "false"),
                http = responseClient(400, """{"error":"$code","error_description":"$PRIVATE","access_token":"$PRIVATE","client_secret":"$PRIVATE","code":"$PRIVATE"}"""))
            val before = f.diskState()
            val error = failure { f.oauth.refreshGoogle() }
            assertSanitized(error)
            assertTrue(error.message.orEmpty().contains(code))
            assertTrue(error.message.orEmpty().contains("HTTP 400"))
            if (code == "invalid_client") {
                assertTrue(error.message.orEmpty().contains(if (custom) "Desktop app" else "app maintainer"))
                assertEquals(custom, error.message.orEmpty().contains("advanced settings"))
            } else assertTrue(error.message.orEmpty().contains("Connect Google Drive"))
            assertEquals(before, f.diskState())
        }
    }

    @Test fun unknownOrMalformedGoogleHttpBodiesCannotEscapeWhitelist() {
        for (body in listOf(
            """{"error":"$PRIVATE","error_description":"$PRIVATE"}""",
            """{"error":"invalid_client $PRIVATE"}""", """{"error":{"code":"invalid_client","message":"$PRIVATE"}}""",
            """{"error":["$PRIVATE"]}""", """{"error":42}""", "[]", "null", "<html>$PRIVATE</html>", "",
        )) {
            val f = fixture(http = responseClient(401, body))
            val before = f.diskState()
            val error = failure { f.oauth.refreshGoogle() }
            assertSanitized(error)
            assertTrue(error.message.orEmpty().contains("HTTP 401"))
            assertFalse(error.message.orEmpty().contains("invalid_client"))
            assertEquals(before, f.diskState())
        }
    }

    @Test fun callbackErrorsUseSameWhitelistAndKeepAdvancedGuidanceOutOfNormalMode() {
        for (custom in listOf(false, true)) {
            val known = DesktopOAuth.googleErrorMessage("invalid_client", useCustom = custom)
            assertTrue(known.contains("invalid_client"))
            assertEquals(custom, known.contains("advanced settings"))
            val unknown = DesktopOAuth.googleErrorMessage(PRIVATE, useCustom = custom)
            assertFalse(unknown.contains(PRIVATE))
            assertFalse(unknown.contains("invalid_client"))
        }
    }

    @Test fun malformedGoogleCallbackEncodingCannotExposeDecoderDetails() {
        for (query in listOf("state=fixture&code=%$PRIVATE", "error=%", "state=%XY&code=$PRIVATE")) {
            val error = failure { DesktopOAuth.googleCallbackValues(query) }
            assertEquals("Google returned an invalid authorization callback. Try Connect Google Drive again.", error.message)
            assertSanitized(error)
        }
        assertEquals(mapOf("state" to "fixture", "code" to "fixture+code"),
            DesktopOAuth.googleCallbackValues("state=fixture&code=fixture%2Bcode"))
    }

    @Test fun malformedSuccessfulGoogleResponsesCannotExposeJsonOrPartiallySaveTokens() {
        for (body in listOf(
            "<html>$PRIVATE</html>", "null", "[]", """{"error":"$PRIVATE"}""",
            """{"access_token":{"private":"$PRIVATE"}}""", """{"access_token":42}""",
            """{"access_token":"$PRIVATE","refresh_token":{"private":"$PRIVATE"}}""",
            """{"access_token":"$PRIVATE","expires_in":{"private":"$PRIVATE"}}""",
            """{"access_token":"$PRIVATE","expires_in":-1}""",
        )) {
            val f = fixture(http = responseClient(body = body))
            val before = f.diskState()
            assertSanitized(failure { f.oauth.refreshGoogle() })
            assertEquals(before, f.diskState())
        }
    }

    @Test fun transportExceptionsCannotExposeRequestOrCauseDetails() {
        val http = OkHttpClient.Builder().addInterceptor { throw IOException(PRIVATE, IOException(CUSTOM_SECRET)) }.build()
        val f = fixture(http = http)
        val before = f.diskState()
        val error = failure { f.oauth.refreshGoogle() }
        assertSanitized(error)
        assertTrue(error.message.orEmpty().contains("network connection"))
        assertEquals(before, f.diskState())
    }

    @Test fun aModeChangeDuringHttpCannotReviveTheOldGrant() {
        lateinit var f: Fixture
        val http = responseClient { assertTrue(f.oauth.setGoogleConnectionMode(false)) }
        f = fixture(mapOf(CLIENT_ID to CUSTOM_ID, MODE to "true"), http = http)
        val others = f.otherProviders()
        val error = failure { f.oauth.refreshGoogle() }
        assertTrue(error.message.orEmpty().contains("settings changed"))
        f.assertInvalidated()
        assertEquals(others, f.otherProviders())
        assertEquals(CUSTOM_SECRET, f.secrets.read(CLIENT_SECRET))
    }

    private fun fixture(
        values: Map<String, String> = emptyMap(),
        defaults: DesktopGoogleClient = DesktopGoogleClient(BUNDLED_ID, BUNDLED_SECRET),
        http: OkHttpClient = OkHttpClient.Builder().addInterceptor { throw AssertionError("Unexpected HTTP request") }.build(),
    ) = Fixture(temporary.newFolder().toPath(), values, defaults, http)

    private class Fixture(val root: Path, values: Map<String, String>, defaults: DesktopGoogleClient, http: OkHttpClient) {
        val settingsFile = root.resolve("settings.properties")
        val secretFile = root.resolve("credentials.properties")
        val settings = DesktopSettings(settingsFile).apply {
            save(mapOf(
                "credentials.plaintext" to "true", ENABLED to "true", "dropbox.enabled" to "true",
                "dropbox.appKey" to "fixture-dropbox-app", "pcloud.enabled" to "true", "pcloud.appKey" to "fixture-pcloud-app",
                "folder.enabled" to "true", "folder.path" to "fixture-folder", "ai.model" to "fixture-model",
            ) + values)
        }
        val secrets = DesktopSecrets(root, settings).apply {
            // Preseed every key read by OAuth. Even on Windows/Linux a missing fallback key must
            // never fall through to the user's OS vault. All writes here use the temp fallback.
            (SEEDED_TOKENS + mapOf(
                CLIENT_SECRET to CUSTOM_SECRET, "dropbox.accessToken" to "fixture-dropbox-access",
                "dropbox.refreshToken" to "fixture-dropbox-refresh", "dropbox.expiresAt" to "123",
                "pcloud.accessToken" to "fixture-pcloud-access", "pcloud.apiHost" to "eapi.pcloud.com",
                "pcloud.refreshToken" to "fixture-pcloud-refresh", "pcloud.expiresAt" to "456",
                "ai.apiKey" to "fixture-ai-key", "webdav.password" to "fixture-webdav-password", "sftp.password" to "fixture-sftp-password",
            )).forEach { (key, value) -> write(key, value) }
        }
        val oauth = DesktopOAuth(settings, secrets, http = http, defaults = defaults)
        fun tokens() = SEEDED_TOKENS.keys.associateWith { secrets.read(it) }
        fun seedTokens() = SEEDED_TOKENS.forEach { (key, value) -> secrets.write(key, value) }
        fun diskState() = readProperties(settingsFile) to readProperties(secretFile)
        fun otherProviders() = readProperties(settingsFile).filterKeys { !it.startsWith("googleDrive.") } to
            readProperties(secretFile).filterKeys { !it.startsWith("CloudReader|googleDrive.") }
        fun assertInvalidated() {
            assertEquals("false", settings.get(ENABLED))
            assertEquals("false", readProperties(settingsFile)[ENABLED])
            for (key in SEEDED_TOKENS.keys) {
                assertEquals("", secrets.read(key))
                assertEquals("", readProperties(secretFile)["CloudReader|$key"])
            }
        }
    }

    companion object {
        private const val CLIENT_ID = "googleDrive.clientID"
        private const val CLIENT_SECRET = "googleDrive.clientSecret"
        private const val MODE = "googleDrive.useCustomCredentials"
        private const val ENABLED = "googleDrive.enabled"
        private const val CUSTOM_ID = "fixture-custom.apps.googleusercontent.com"
        private const val CUSTOM_SECRET = "fixture-custom-secret"
        private const val OTHER_ID = "fixture-other.apps.googleusercontent.com"
        private const val BUNDLED_ID = "fixture-bundled.apps.googleusercontent.com"
        private const val BUNDLED_SECRET = "fixture-bundled-secret"
        private const val PRIVATE = "PRIVATE_RESPONSE_CODE_TOKEN_SECRET_FIXTURE"
        private val SEEDED_TOKENS = mapOf(
            "googleDrive.accessToken" to "fixture-google-access",
            "googleDrive.refreshToken" to "fixture-google-refresh",
            "googleDrive.expiresAt" to "0",
        )

        private fun readProperties(path: Path): Map<String, String> {
            val properties = Properties().apply { Files.newBufferedReader(path).use { load(it) } }
            return properties.stringPropertyNames().associateWith { properties.getProperty(it) }
        }

        private fun failure(block: () -> Unit): Exception {
            try { block() } catch (error: Exception) { return error }
            throw AssertionError("Expected an exception")
        }

        private fun assertSanitized(error: Exception) {
            assertNull(error.cause)
            for (value in listOf(PRIVATE, CUSTOM_ID, CUSTOM_SECRET, BUNDLED_ID, BUNDLED_SECRET) + SEEDED_TOKENS.values.filter { it != "0" }) {
                assertFalse("Exception exposed fixture details", error.stackTraceToString().contains(value))
            }
        }

        private fun blockFile(path: Path): Path {
            val backup = path.resolveSibling(path.fileName.toString() + ".backup")
            Files.move(path, backup)
            Files.createDirectory(path)
            Files.writeString(path.resolve("blocker"), "fixture")
            return backup
        }

        private fun restoreFile(path: Path, backup: Path) {
            Files.delete(path.resolve("blocker"))
            Files.delete(path)
            Files.move(backup, path)
        }

        private fun responseClient(
            status: Int = 200,
            body: String = """{"access_token":"fixture-new-access","expires_in":3600}""",
            inspect: (Request) -> Unit = {},
        ): OkHttpClient = OkHttpClient.Builder().addInterceptor { chain ->
            // Never call proceed: all requests terminate in this interceptor, without network.
            val request = chain.request()
            assertEquals("https://oauth2.googleapis.com/token", request.url.toString())
            inspect(request)
            Response.Builder().request(request).protocol(Protocol.HTTP_1_1).code(status).message("fixture")
                .body(body.toResponseBody("application/json".toMediaType())).build()
        }.build()

        private fun requestForm(request: Request): Map<String, String> {
            val buffer = Buffer()
            request.body!!.writeTo(buffer)
            return buffer.readUtf8().split('&').associate { entry ->
                URLDecoder.decode(entry.substringBefore('='), "UTF-8") to URLDecoder.decode(entry.substringAfter('='), "UTF-8")
            }
        }
    }
}
