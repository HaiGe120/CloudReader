package io.github.haige120.cloudreader.sync

internal enum class GoogleAuthorizationStage(val description: String) {
    REQUEST("authorization request"),
    CALLBACK("returned authorization result"),
    RENEWAL("token renewal request"),
}

internal class GoogleAuthorizationException(message: String, val requiresSetup: Boolean, cause: Throwable) : IllegalStateException(message, cause)

/** Formats provider failures without retaining tokens or account identifiers in the visible detail. */
internal object GoogleAuthorizationDiagnostics {
    private const val MAX_DETAIL_LENGTH = 512
    private val credentialAssignment = Regex(
        """(?i)(\b(?:access[_ -]?token|refresh[_ -]?token|id[_ -]?token|token|auth(?:orization)?[_ -]?code|server[_ -]?auth[_ -]?code|client[_ -]?secret|password)\b["']?\s*[:=]\s*["']?)([^"'\s,;&}\]]+)""",
    )
    private val codeQueryParameter = Regex("""(?i)(\bcode\s*=\s*["']?)([^"'\s,;&}\]]+)""")
    private val bearerCredential = Regex("""(?i)(\bBearer\s+)([A-Za-z0-9._~+/=-]+)""")
    private val googleCredential = Regex("""\b(?:ya29\.|4/|1//|4%2[Ff]|1%2[Ff]%2[Ff])[A-Za-z0-9._~+/%=-]+""")
    private val jwtCredential = Regex("""\beyJ[A-Za-z0-9_-]*\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+""")
    private val emailAddress = Regex("""(?i)\b[A-Z0-9._%+-]+(?:@|%40)[A-Z0-9.-]+\.[A-Z]{2,}\b""")

    fun requiresSetup(code: Int?, providerMessage: String?): Boolean =
        code in listOf(10, 12500) || providerMessage.orEmpty().contains("UNREGISTERED_ON_API_CONSOLE", ignoreCase = true)

    fun message(
        code: Int?,
        providerMessage: String?,
        stage: GoogleAuthorizationStage,
        registration: String? = null,
    ): String {
        val explanation = when {
            providerMessage.orEmpty().contains("UNREGISTERED_ON_API_CONSOLE", ignoreCase = true) ->
                "Google does not recognize CloudReader's Android registration. The app's Google project owner must register this build's package and signing certificate. See Google connection help."
            else -> when (code) {
            8 -> "Google Play services reported an internal authorization error. Tap Connect to try again. If it continues, check Google Play services, the network, and the Android OAuth registration."
            10, 12500 -> "Google could not verify this Android app. CloudReader's Google connection needs attention from the app maintainer. See Google connection help."
            7 -> "Google Drive could not connect to Google. Check the network and try again."
            16, 12501 -> "Google Drive authorization was cancelled or access was not granted. Tap Connect to try again."
            else -> "Google Drive authorization could not be completed. Tap Connect to try again."
            }
        }
        val detail = providerMessage?.let(::redact)
            ?.removePrefix("$code:")?.trim()
            ?.takeIf { it.isNotBlank() && it != code?.toString() }
        return buildString {
            append(explanation)
            if (requiresSetup(code, providerMessage)) append("\nMaintainer setup: Register its Android OAuth client with the package and SHA-1 below, enable the Drive API, and check the consent-screen test users. Custom Web credentials must belong to the same project; a Web client ID and secret alone cannot register Android.")
            if (code != null) append("\nGoogle error code: $code")
            append("\nStage: ${stage.description}")
            detail?.let { append("\nGoogle details: $it") }
            if ((code == 8 || requiresSetup(code, providerMessage)) && !registration.isNullOrBlank()) {
                append("\nAndroid OAuth registration to check:\n$registration")
            }
        }
    }

    private fun redact(value: String): String {
        var result = credentialAssignment.replace(value) { "${it.groupValues[1]}[redacted]" }
        result = codeQueryParameter.replace(result) { "${it.groupValues[1]}[redacted]" }
        result = bearerCredential.replace(result) { "${it.groupValues[1]}[redacted]" }
        result = googleCredential.replace(result, "[redacted]")
        result = jwtCredential.replace(result, "[redacted]")
        result = emailAddress.replace(result, "[redacted]")
        return result.replace(Regex("[\\r\\n\\t]+"), " ")
            .filterNot(Char::isISOControl)
            .trim()
            .take(MAX_DETAIL_LENGTH)
    }
}
