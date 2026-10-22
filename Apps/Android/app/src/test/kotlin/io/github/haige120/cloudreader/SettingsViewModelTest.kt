package io.github.haige120.cloudreader

import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class SettingsViewModelTest {
    @Test fun loadsExistingValuesAndProviderFlowAndKeepsDefaults() = runTest {
        val store = FakeSettingsStore().apply {
            values["ai.model"] = "gpt-test"
            secrets["sftp.port"] = "2222"
            selected.value = setOf("googleDrive")
        }
        val model = SettingsViewModel(store, backgroundScope)
        val collector = backgroundScope.launch { model.state.collect {} }
        runCurrent()

        assertEquals("My AI", model.state.value.aiName)
        assertEquals("openAIResponses", model.state.value.aiProtocol)
        assertEquals("gpt-test", model.state.value.aiModel)
        assertEquals("2222", model.state.value.sftpPort)
        assertEquals(setOf("googleDrive"), model.state.value.selectedProviders)

        store.selected.value = setOf("googleDrive", "webDAV")
        runCurrent()
        assertEquals(setOf("googleDrive", "webDAV"), model.state.value.selectedProviders)
        collector.cancel()
    }

    @Test fun savesWebDavAndSftpValuesAndSelectsProviders() = runTest {
        val store = FakeSettingsStore()
        val model = SettingsViewModel(store, backgroundScope)
        runCurrent()
        model.update(SettingsField.WEBDAV_URL, "https://dav.example/path/")
        model.update(SettingsField.WEBDAV_USER, "reader")
        model.update(SettingsField.WEBDAV_PASSWORD, "secret")
        model.saveWebDav()
        runCurrent()
        assertEquals("https://dav.example/path", store.values["webdav.url"])
        assertEquals("reader", store.secrets["webdav.username"])
        assertEquals("secret", store.secrets["webdav.password"])
        assertTrue("webDAV" in store.selected.value)

        model.update(SettingsField.SFTP_DIRECTORY, "/books/")
        model.update(SettingsField.SFTP_KEY, "ssh-ed25519 AAAA")
        model.saveSftp()
        runCurrent()
        assertEquals("books", store.secrets["sftp.directory"])
        assertEquals("ssh-ed25519 AAAA", store.secrets["sftp.hostKey"])
        assertEquals("", store.secrets["sftp.password"])
        assertTrue("sftp" in store.selected.value)
    }

    @Test fun blankPasswordsRetainSavedConnectionsAndReplacementsSurviveAnotherSave() = runTest {
        val store = FakeSettingsStore().apply {
            values["webdav.url"] = "https://dav.example"
            secrets["webdav.password"] = "existing-dav"
            secrets["sftp.password"] = "existing-sftp"
            secrets["sftp.hostKey"] = "ssh-ed25519 AAAA"
        }
        val model = SettingsViewModel(store, backgroundScope)
        runCurrent()

        assertEquals("", model.state.value.webdavPassword)
        assertEquals("", model.state.value.sftpPassword)
        model.saveWebDav()
        model.saveSftp()
        runCurrent()
        assertEquals("existing-dav", store.secrets["webdav.password"])
        assertEquals("existing-sftp", store.secrets["sftp.password"])

        model.update(SettingsField.WEBDAV_PASSWORD, "replacement-dav")
        model.update(SettingsField.SFTP_PASSWORD, "replacement-sftp")
        model.saveWebDav()
        model.saveSftp()
        runCurrent()
        assertEquals("replacement-dav", store.secrets["webdav.password"])
        assertEquals("replacement-sftp", store.secrets["sftp.password"])
        assertEquals("", model.state.value.webdavPassword)
        assertEquals("", model.state.value.sftpPassword)

        model.saveWebDav()
        model.saveSftp()
        runCurrent()
        assertEquals("replacement-dav", store.secrets["webdav.password"])
        assertEquals("replacement-sftp", store.secrets["sftp.password"])
    }

    @Test fun rejectsInsecureAiAndWebDavAndPreservesAiSecretWhenBlank() = runTest {
        val store = FakeSettingsStore().apply { secrets["ai.apiKey"] = "existing" }
        val model = SettingsViewModel(store, backgroundScope)
        runCurrent()
        model.update(SettingsField.WEBDAV_URL, "http://dav.example")
        model.saveWebDav()
        runCurrent()
        assertEquals("WebDAV needs an HTTPS URL.", model.state.value.message)
        assertEquals(emptySet<String>(), store.selected.value)

        model.consumeMessage()
        model.update(SettingsField.AI_MODEL, " model-id ")
        model.update(SettingsField.AI_ENDPOINT, "http://ai.example")
        model.saveAi()
        runCurrent()
        assertEquals("AI endpoints must use HTTPS.", model.state.value.message)
        assertEquals("existing", store.secrets["ai.apiKey"])
        model.consumeMessage()
        model.update(SettingsField.AI_ENDPOINT, "")
        model.saveAi()
        runCurrent()
        assertEquals("model-id", store.values["ai.model"])
        assertEquals("existing", store.secrets["ai.apiKey"])
        assertEquals("AI profile saved", model.state.value.message)
    }

    private class FakeSettingsStore : SettingsStore {
        val selected = MutableStateFlow<Set<String>>(emptySet())
        val values = mutableMapOf<String, String>()
        val secrets = mutableMapOf<String, String>()
        override val selectedProviders = selected
        override val folderName = MutableStateFlow("")
        override suspend fun get(key: String) = values[key]
        override fun getSecret(key: String) = secrets[key]
        override suspend fun set(key: String, value: String) { values[key] = value }
        override fun setSecret(key: String, value: String) { secrets[key] = value }
        override suspend fun selectProvider(id: String, selected: Boolean) {
            this.selected.value = this.selected.value.toMutableSet().apply { if (selected) add(id) else remove(id) }
        }
    }
}
