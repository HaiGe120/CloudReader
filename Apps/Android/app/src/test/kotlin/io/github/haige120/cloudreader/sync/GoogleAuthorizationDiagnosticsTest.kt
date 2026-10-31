package io.github.haige120.cloudreader.sync

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class GoogleAuthorizationDiagnosticsTest {
    private val registration = "Package: io.github.haige120.cloudreader\nSHA-1: E3:F7:0B:33"

    @Test fun internalErrorRetainsProviderReasonAndRegistrationWithoutClaimingACause() {
        val message = GoogleAuthorizationDiagnostics.message(
            8, "8: [28444] Authorization service is temporarily unavailable", GoogleAuthorizationStage.CALLBACK, registration,
        )
        assertTrue(message.contains("internal authorization error"))
        assertTrue(message.contains("Tap Connect to try again"))
        assertTrue(message.contains("Google error code: 8"))
        assertTrue(message.contains("Stage: returned authorization result"))
        assertTrue(message.contains("[28444] Authorization service is temporarily unavailable"))
        assertTrue(message.contains("Android OAuth registration to check:\n$registration"))
        assertFalse(message.contains("could not verify this Android app"))
        assertFalse(message.contains("misconfigured"))
    }

    @Test fun configurationErrorShowsRegistrationInstructions() {
        val message = GoogleAuthorizationDiagnostics.message(
            10, "10: App not registered", GoogleAuthorizationStage.REQUEST, registration,
        )
        assertTrue(message.contains("Register its Android OAuth client"))
        assertTrue(message.contains("enable the Drive API"))
        assertTrue(message.contains(registration))
        assertTrue(message.contains("Stage: authorization request"))
        assertTrue(message.contains("App not registered"))
    }

    @Test fun networkAndCancellationErrorsKeepTheirSpecificRecovery() {
        val network = GoogleAuthorizationDiagnostics.message(7, "7: Network unavailable", GoogleAuthorizationStage.RENEWAL, registration)
        assertTrue(network.contains("Check the network"))
        assertTrue(network.contains("Stage: token renewal request"))
        assertFalse(network.contains(registration))
        val cancelled = GoogleAuthorizationDiagnostics.message(16, null, GoogleAuthorizationStage.CALLBACK, registration)
        assertTrue(cancelled.contains("cancelled or access was not granted"))
        assertTrue(cancelled.contains("Tap Connect to try again"))
        assertFalse(cancelled.contains(registration))
    }

    @Test fun credentialsAndAccountIdentifiersAreRedactedBeforeDisplay() {
        val secrets = listOf("access-secret", "refresh-secret", "id-secret", "auth-secret", "server-secret", "client-secret", "password-secret", "generic-secret", "query-secret", "bearer-secret", "someone@example.com")
        val details = """8: service failed access_token=access-secret refreshToken="refresh-secret" id_token:id-secret authorization_code=auth-secret serverAuthCode=server-secret client_secret=client-secret password=password-secret token=generic-secret https://example.com?code=query-secret&error=temporarily_unavailable Bearer bearer-secret someone@example.com"""
        val message = GoogleAuthorizationDiagnostics.message(8, details, GoogleAuthorizationStage.CALLBACK)
        secrets.forEach { secret -> assertFalse("Leaked $secret", message.contains(secret)) }
        assertTrue(message.contains("service failed"))
        assertTrue(message.contains("temporarily_unavailable"))
        assertTrue(message.contains("[redacted]"))
    }

    @Test fun unlabeledGoogleTokensCodesJwtAndEncodedEmailAreRedacted() {
        val secrets = listOf("ya29.accessSecret", "4/authSecret", "1//refreshSecret", "4%2FencodedCode", "eyJhbGciOiJIUzI1NiJ9.payload.signature", "someone%40example.com")
        val message = GoogleAuthorizationDiagnostics.message(8, "Provider failed: ${secrets.joinToString(" ")}", GoogleAuthorizationStage.CALLBACK)
        secrets.forEach { secret -> assertFalse("Leaked $secret", message.contains(secret)) }
        assertTrue(message.contains("Provider failed:"))
    }

    @Test fun detailedProviderTextIsBoundedAndControlCharactersRemoved() {
        val message = GoogleAuthorizationDiagnostics.message(8, "8: service\nfailed\t\u0000${"x".repeat(2_000)}", GoogleAuthorizationStage.REQUEST)
        val details = message.substringAfter("Google details: ")
        assertTrue(details.length <= 512)
        assertTrue(details.startsWith("service failed "))
        assertFalse(details.any(Char::isISOControl))
    }

    @Test fun redactionBeforeLengthLimitCannotExposeATruncatedSecret() {
        val secret = "very-secret-".repeat(100)
        val message = GoogleAuthorizationDiagnostics.message(8, "8: reason token=$secret", GoogleAuthorizationStage.REQUEST)
        assertFalse(message.contains("very-secret"))
        assertTrue(message.contains("token=[redacted]"))
    }

    @Test fun emptyOrCodeOnlyMessagesDoNotAddAnEmptyDetailLine() {
        listOf(null, "", "   ", "8", "8: ").forEach { detail ->
            val message = GoogleAuthorizationDiagnostics.message(8, detail, GoogleAuthorizationStage.CALLBACK)
            assertFalse(message.contains("Google details:"))
            assertTrue(message.contains("Google error code: 8"))
        }
    }

    @Test fun missingTokenFailureIsVisibleWithoutInventingAnApiErrorCode() {
        val message = GoogleAuthorizationDiagnostics.message(
            null, "Google returned an authorization result without an access token.", GoogleAuthorizationStage.CALLBACK,
        )
        assertTrue(message.contains("without an access token"))
        assertTrue(message.contains("Stage: returned authorization result"))
        assertFalse(message.contains("Google error code:"))
    }
}
