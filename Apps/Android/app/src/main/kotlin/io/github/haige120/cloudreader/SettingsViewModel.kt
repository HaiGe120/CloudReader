package io.github.haige120.cloudreader

import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewModelScope
import androidx.lifecycle.viewmodel.CreationExtras
import io.github.haige120.cloudreader.data.CloudReaderPreferences
import io.github.haige120.cloudreader.data.SecureVault
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.launch

data class SettingsUiState(
    val selectedProviders: Set<String> = emptySet(),
    val folderName: String = "",
    val dropboxKey: String = "",
    val pcloudKey: String = "",
    val webdavUrl: String = "",
    val webdavUser: String = "",
    val webdavPassword: String = "",
    val sftpHost: String = "",
    val sftpPort: String = "22",
    val sftpUser: String = "",
    val sftpPassword: String = "",
    val sftpDirectory: String = "CloudReader",
    val sftpKey: String = "",
    val aiName: String = "My AI",
    val aiProtocol: String = "openAIResponses",
    val aiModel: String = "",
    val aiEndpoint: String = "",
    val aiKey: String = "",
    val message: String? = null,
)

enum class SettingsField {
    DROPBOX_KEY, PCLOUD_KEY, WEBDAV_URL, WEBDAV_USER, WEBDAV_PASSWORD,
    SFTP_HOST, SFTP_PORT, SFTP_USER, SFTP_PASSWORD, SFTP_DIRECTORY, SFTP_KEY,
    AI_NAME, AI_PROTOCOL, AI_MODEL, AI_ENDPOINT, AI_KEY,
}

interface SettingsStore {
    val selectedProviders: Flow<Set<String>>
    val folderName: Flow<String>
    suspend fun get(key: String): String?
    fun getSecret(key: String): String?
    suspend fun set(key: String, value: String)
    fun setSecret(key: String, value: String)
    suspend fun selectProvider(id: String, selected: Boolean)
}

class SettingsViewModel(
    private val store: SettingsStore,
    private val stateScope: CoroutineScope? = null,
) : ViewModel() {
    private val mutableState = MutableStateFlow(SettingsUiState())
    val state: StateFlow<SettingsUiState> = mutableState.asStateFlow()
    private val scope get() = stateScope ?: viewModelScope

    init {
        scope.launch {
            store.selectedProviders.collect { providers -> mutableState.value = mutableState.value.copy(selectedProviders = providers.toSet()) }
        }
        scope.launch {
            store.folderName.collect { folder -> mutableState.value = mutableState.value.copy(folderName = folder) }
        }
        scope.launch {
            mutableState.value = mutableState.value.copy(
                dropboxKey = store.get("dropbox.appKey").orEmpty(),
                pcloudKey = store.get("pcloud.appKey").orEmpty(),
                webdavUrl = store.get("webdav.url").orEmpty(),
                webdavUser = store.getSecret("webdav.username").orEmpty(),
                sftpHost = store.getSecret("sftp.host").orEmpty(),
                sftpPort = store.getSecret("sftp.port") ?: "22",
                sftpUser = store.getSecret("sftp.username").orEmpty(),
                sftpDirectory = store.getSecret("sftp.directory") ?: "CloudReader",
                sftpKey = store.getSecret("sftp.hostKey").orEmpty(),
                aiName = store.get("ai.name") ?: "My AI",
                aiProtocol = store.get("ai.protocol") ?: "openAIResponses",
                aiModel = store.get("ai.model").orEmpty(),
                aiEndpoint = store.get("ai.endpoint").orEmpty(),
            )
        }
    }

    fun update(field: SettingsField, value: String) {
        mutableState.value = when (field) {
            SettingsField.DROPBOX_KEY -> mutableState.value.copy(dropboxKey = value)
            SettingsField.PCLOUD_KEY -> mutableState.value.copy(pcloudKey = value)
            SettingsField.WEBDAV_URL -> mutableState.value.copy(webdavUrl = value)
            SettingsField.WEBDAV_USER -> mutableState.value.copy(webdavUser = value)
            SettingsField.WEBDAV_PASSWORD -> mutableState.value.copy(webdavPassword = value)
            SettingsField.SFTP_HOST -> mutableState.value.copy(sftpHost = value)
            SettingsField.SFTP_PORT -> mutableState.value.copy(sftpPort = value)
            SettingsField.SFTP_USER -> mutableState.value.copy(sftpUser = value)
            SettingsField.SFTP_PASSWORD -> mutableState.value.copy(sftpPassword = value)
            SettingsField.SFTP_DIRECTORY -> mutableState.value.copy(sftpDirectory = value)
            SettingsField.SFTP_KEY -> mutableState.value.copy(sftpKey = value)
            SettingsField.AI_NAME -> mutableState.value.copy(aiName = value)
            SettingsField.AI_PROTOCOL -> mutableState.value.copy(aiProtocol = value)
            SettingsField.AI_MODEL -> mutableState.value.copy(aiModel = value)
            SettingsField.AI_ENDPOINT -> mutableState.value.copy(aiEndpoint = value)
            SettingsField.AI_KEY -> mutableState.value.copy(aiKey = value)
        }
    }

    fun selectProvider(id: String, selected: Boolean) = scope.launch { store.selectProvider(id, selected) }

    fun saveProviderIDs() = runAction("Provider app identifiers saved") {
        store.set("dropbox.appKey", state.value.dropboxKey)
        store.set("pcloud.appKey", state.value.pcloudKey)
    }

    fun saveWebDav() = runAction("WebDAV connection saved and selected") {
        val s = state.value
        require(s.webdavUrl.startsWith("https://")) { "WebDAV needs an HTTPS URL." }
        store.set("webdav.url", s.webdavUrl.trimEnd('/'))
        store.setSecret("webdav.username", s.webdavUser)
        if (s.webdavPassword.isNotBlank() || store.getSecret("webdav.password") == null) {
            store.setSecret("webdav.password", s.webdavPassword)
        }
        store.selectProvider("webDAV", true)
    }

    fun saveSftp() = runAction("SFTP details saved and selected") {
        val s = state.value
        require(s.sftpKey.trim().split(Regex("\\s+")).size >= 2) { "Enter the server host public key to pin." }
        store.setSecret("sftp.host", s.sftpHost)
        store.setSecret("sftp.port", s.sftpPort)
        store.setSecret("sftp.username", s.sftpUser)
        if (s.sftpPassword.isNotBlank() || store.getSecret("sftp.password") == null) {
            store.setSecret("sftp.password", s.sftpPassword)
        }
        store.setSecret("sftp.directory", s.sftpDirectory.trim('/'))
        store.setSecret("sftp.hostKey", s.sftpKey.trim())
        store.selectProvider("sftp", true)
    }

    fun saveAi() = runAction("AI profile saved") {
        val s = state.value
        require(s.aiModel.isNotBlank()) { "Add a model ID." }
        if (s.aiEndpoint.isNotBlank()) require(s.aiEndpoint.startsWith("https://")) { "AI endpoints must use HTTPS." }
        store.set("ai.name", s.aiName.ifBlank { "My AI" })
        store.set("ai.protocol", s.aiProtocol)
        store.set("ai.model", s.aiModel.trim())
        store.set("ai.endpoint", s.aiEndpoint.trim())
        if (s.aiKey.isNotBlank()) store.setSecret("ai.apiKey", s.aiKey.trim())
    }

    fun consumeMessage() { mutableState.value = mutableState.value.copy(message = null) }

    private fun runAction(success: String, action: suspend () -> Unit) = scope.launch {
        runCatching { action() }
            .onSuccess {
                mutableState.value = mutableState.value.copy(
                    message = success,
                    webdavPassword = if (success.startsWith("WebDAV")) "" else mutableState.value.webdavPassword,
                    sftpPassword = if (success.startsWith("SFTP")) "" else mutableState.value.sftpPassword,
                    aiKey = if (success.startsWith("AI")) "" else mutableState.value.aiKey,
                )
            }
            .onFailure { mutableState.value = mutableState.value.copy(message = it.localizedMessage ?: "Settings could not be saved") }
    }

    companion object {
        fun factory(app: CloudReaderApp): ViewModelProvider.Factory = object : ViewModelProvider.Factory {
            @Suppress("UNCHECKED_CAST")
            override fun <T : ViewModel> create(modelClass: Class<T>, extras: CreationExtras): T {
                require(SettingsViewModel::class.java.isAssignableFrom(modelClass))
                val prefs = app.preferences
                val vault = app.vault
                return SettingsViewModel(object : SettingsStore {
                    override val selectedProviders = prefs.selectedProviders
                    override val folderName = prefs.observe("folder.treeUri", "")
                    override suspend fun get(key: String) = prefs.get(key)
                    override fun getSecret(key: String) = vault.get(key)
                    override suspend fun set(key: String, value: String) = prefs.set(key, value)
                    override fun setSecret(key: String, value: String) = vault.put(key, value)
                    override suspend fun selectProvider(id: String, selected: Boolean) = prefs.selectProvider(id, selected)
                }) as T
            }
        }
    }
}
