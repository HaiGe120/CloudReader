package io.github.haige120.cloudreader

import android.app.Activity
import androidx.credentials.*
import androidx.credentials.exceptions.CreateCredentialCancellationException
import androidx.credentials.exceptions.GetCredentialCancellationException
import kotlinx.coroutines.CancellationException
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

@Serializable
internal data class AiSettingsCopy(
    val version: Int = 1,
    val name: String, val protocol: String, val endpoint: String, val model: String,
    val webSearch: Boolean, val offlineFallback: Boolean, val apiKey: String?,
)

internal suspend fun transferAiSettings(activity: Activity, model: SettingsViewModel, save: Boolean, message: (String) -> Unit) {
    val manager = CredentialManager.create(activity)
    val id = "CloudReader AI profile"
    try {
        if (save) {
            val copy = Json.encodeToString(AiSettingsCopy.serializer(), model.exportAi())
            manager.createCredential(activity, CreatePasswordRequest(id, copy))
            message("AI profile saved to your password manager.")
        } else {
            val credential = manager.getCredential(activity, GetCredentialRequest(listOf(GetPasswordOption()))).credential
            require(credential is PasswordCredential && credential.id == id) { "Choose the CloudReader AI profile entry." }
            model.importAi(Json.decodeFromString(AiSettingsCopy.serializer(), credential.password))
        }
    } catch (cancelled: CancellationException) { throw cancelled }
    catch (_: CreateCredentialCancellationException) { }
    catch (_: GetCredentialCancellationException) { }
    catch (_: androidx.credentials.exceptions.NoCredentialException) { message("No saved CloudReader AI profile was found in your password manager.") }
    catch (_: Exception) { message("Could not transfer the saved AI profile. Check your password manager and saved profile.") }
}
