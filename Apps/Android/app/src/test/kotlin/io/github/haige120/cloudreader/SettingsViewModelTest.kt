package io.github.haige120.cloudreader

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class SettingsViewModelTest {
    @Test fun googleSaveIsBusyImmediatelySnapshotsDraftAndIgnoresDuplicatesWhileStorageSuspends() = runTest {
        val gate = CompletableDeferred<Unit>()
        val store = FakeSettingsStore().apply { beforeGoogleSet = { gate.await() } }
        val model = SettingsViewModel(store, backgroundScope)
        runCurrent()
        model.update(SettingsField.GOOGLE_CLIENT_ID, "123-submitted.apps.googleusercontent.com")
        model.update(SettingsField.GOOGLE_CLIENT_SECRET, "submitted-secret")
        model.saveGoogleCredentials()
        assertTrue(model.state.value.googleCredentialsSaving)
        model.update(SettingsField.GOOGLE_CLIENT_ID, "456-new-draft.apps.googleusercontent.com")
        model.update(SettingsField.GOOGLE_CLIENT_SECRET, "new-draft-secret")
        model.saveGoogleCredentials()
        runCurrent()

        assertTrue(model.state.value.googleCredentialsSaving)
        assertEquals(1, store.googleSetCalls)
        assertNull(store.values["googleDrive.clientID"])
        assertEquals("submitted-secret", store.secrets["googleDrive.clientSecret"])
        model.saveGoogleCredentials()
        runCurrent()
        assertEquals(1, store.googleSetCalls)

        gate.complete(Unit)
        runCurrent()
        assertFalse(model.state.value.googleCredentialsSaving)
        assertEquals("123-submitted.apps.googleusercontent.com", store.values["googleDrive.clientID"])
        assertEquals("submitted-secret", store.secrets["googleDrive.clientSecret"])
        assertEquals("456-new-draft.apps.googleusercontent.com", model.state.value.googleClientId)
        assertEquals("new-draft-secret", model.state.value.googleClientSecret)
        assertEquals(1, model.state.value.googleCredentialsSavedRevision)

        model.saveGoogleCredentials()
        runCurrent()
        assertEquals("456-new-draft.apps.googleusercontent.com", store.values["googleDrive.clientID"])
        assertEquals("new-draft-secret", store.secrets["googleDrive.clientSecret"])
        assertEquals(2, store.googleSetCalls)
        assertFalse(model.state.value.googleCredentialsSaving)
    }

    @Test fun googleSaveFailureClearsBusyAndAllowsRetryWithoutDroppingDraft() = runTest {
        val store = FakeSettingsStore().apply { beforeGoogleSet = { error("Storage unavailable") } }
        val model = SettingsViewModel(store, backgroundScope)
        runCurrent()
        model.update(SettingsField.GOOGLE_CLIENT_ID, "123-submitted.apps.googleusercontent.com")
        model.update(SettingsField.GOOGLE_CLIENT_SECRET, "submitted-secret")
        model.saveGoogleCredentials()
        assertTrue(model.state.value.googleCredentialsSaving)
        runCurrent()

        assertFalse(model.state.value.googleCredentialsSaving)
        assertEquals("Storage unavailable", model.state.value.message)
        assertEquals("submitted-secret", model.state.value.googleClientSecret)
        assertEquals(0, model.state.value.googleCredentialsSavedRevision)
        assertNull(store.secrets["googleDrive.clientSecret"])

        store.beforeGoogleSet = null
        model.saveGoogleCredentials()
        assertTrue(model.state.value.googleCredentialsSaving)
        runCurrent()
        assertFalse(model.state.value.googleCredentialsSaving)
        assertEquals("123-submitted.apps.googleusercontent.com", store.values["googleDrive.clientID"])
        assertEquals("submitted-secret", store.secrets["googleDrive.clientSecret"])
        assertEquals("", model.state.value.googleClientSecret)
        assertEquals(1, model.state.value.googleCredentialsSavedRevision)
    }

    @Test fun replacingGoogleCredentialsRestoresOldSecretAndGrantWhenClientIdWriteFails() = runTest {
        val store = FakeSettingsStore().apply {
            existingGoogleConnection()
            beforeGoogleSet = { error("Storage unavailable") }
        }
        val previousSecrets = store.secrets.toMap()
        val previousValues = store.values.toMap()
        val previousSelection = store.selected.value
        val model = SettingsViewModel(store, backgroundScope)
        runCurrent()
        model.update(SettingsField.GOOGLE_CLIENT_ID, "456-replacement.apps.googleusercontent.com")
        model.update(SettingsField.GOOGLE_CLIENT_SECRET, "replacement-secret")
        model.saveGoogleCredentials()
        runCurrent()

        assertEquals(previousSecrets, store.secrets)
        assertEquals(previousValues, store.values)
        assertEquals(previousSelection, store.selected.value)
        assertEquals("replacement-secret", model.state.value.googleClientSecret)
        assertEquals("Storage unavailable", model.state.value.message)
        assertEquals(0, model.state.value.googleCredentialsSavedRevision)
        assertFalse(model.state.value.googleCredentialsSaving)
    }

    @Test fun clearingGoogleCredentialsRestoresOldSecretAndGrantWhenClientIdWriteFails() = runTest {
        val store = FakeSettingsStore().apply {
            existingGoogleConnection()
            beforeGoogleSet = { error("Storage unavailable") }
        }
        val previousSecrets = store.secrets.toMap()
        val previousValues = store.values.toMap()
        val previousSelection = store.selected.value
        val model = SettingsViewModel(store, backgroundScope)
        runCurrent()
        model.update(SettingsField.GOOGLE_CLIENT_ID, "")
        model.saveGoogleCredentials()
        runCurrent()

        assertEquals(previousSecrets, store.secrets)
        assertEquals(previousValues, store.values)
        assertEquals(previousSelection, store.selected.value)
        assertEquals("", model.state.value.googleClientId)
        assertEquals("Storage unavailable", model.state.value.message)
        assertEquals(0, model.state.value.googleCredentialsSavedRevision)
        assertFalse(model.state.value.googleCredentialsSaving)
    }

    @Test fun cancelledGoogleClientIdWriteRestoresOldSecretAndGrantAndReleasesBusy() = runTest {
        val gate = CompletableDeferred<Unit>()
        val store = FakeSettingsStore().apply {
            existingGoogleConnection()
            beforeGoogleSet = { gate.await() }
        }
        val previousSecrets = store.secrets.toMap()
        val previousValues = store.values.toMap()
        val previousSelection = store.selected.value
        val model = SettingsViewModel(store, backgroundScope)
        runCurrent()
        model.update(SettingsField.GOOGLE_CLIENT_ID, "456-replacement.apps.googleusercontent.com")
        model.update(SettingsField.GOOGLE_CLIENT_SECRET, "replacement-secret")
        model.saveGoogleCredentials()
        runCurrent()
        assertTrue(model.state.value.googleCredentialsSaving)
        assertEquals("replacement-secret", store.secrets["googleDrive.clientSecret"])

        backgroundScope.cancel()
        runCurrent()
        assertEquals(previousSecrets, store.secrets)
        assertEquals(previousValues, store.values)
        assertEquals(previousSelection, store.selected.value)
        assertEquals(0, model.state.value.googleCredentialsSavedRevision)
        assertFalse(model.state.value.googleCredentialsSaving)
    }

    @Test fun savesCustomGoogleCredentialsWithoutSelectingProviderOrExposingSavedSecret() = runTest {
        val store = FakeSettingsStore()
        val model = SettingsViewModel(store, backgroundScope)
        runCurrent()
        model.update(SettingsField.GOOGLE_CLIENT_ID, " 123-custom.apps.googleusercontent.com ")
        model.update(SettingsField.GOOGLE_CLIENT_SECRET, " custom-secret ")
        model.saveGoogleCredentials()
        runCurrent()

        assertEquals("123-custom.apps.googleusercontent.com", store.values["googleDrive.clientID"])
        assertEquals("custom-secret", store.secrets["googleDrive.clientSecret"])
        assertFalse("googleDrive" in store.selected.value)
        assertEquals("", model.state.value.googleClientSecret)
        assertEquals(1, model.state.value.googleCredentialsSavedRevision)
        assertEquals("Google app credentials saved. Tap Connect to sign in.", model.state.value.message)

        val reloaded = SettingsViewModel(store, backgroundScope)
        runCurrent()
        assertEquals("123-custom.apps.googleusercontent.com", reloaded.state.value.googleClientId)
        assertEquals("", reloaded.state.value.googleClientSecret)
    }

    @Test fun unchangedGoogleSaveRetainsSecretTokensAndProviderSelection() = runTest {
        val store = FakeSettingsStore().apply { existingGoogleConnection() }
        val originalSecrets = store.secrets.toMap()
        val model = SettingsViewModel(store, backgroundScope)
        runCurrent()
        model.saveGoogleCredentials()
        runCurrent()

        assertEquals(originalSecrets, store.secrets)
        assertEquals(setOf("googleDrive", "webDAV"), store.selected.value)
        assertEquals("", model.state.value.googleClientSecret)
    }

    @Test fun changedGoogleClientRequiresNewSecretBeforeInvalidatingOnlyGoogleConnection() = runTest {
        val store = FakeSettingsStore().apply {
            existingGoogleConnection()
            values["dropbox.appKey"] = "dropbox-id"
            secrets["dropbox.accessToken"] = "dropbox-token"
            secrets["webdav.password"] = "webdav-password"
        }
        val originalSecrets = store.secrets.toMap()
        val model = SettingsViewModel(store, backgroundScope)
        runCurrent()
        model.update(SettingsField.GOOGLE_CLIENT_ID, "456-replacement.apps.googleusercontent.com")
        model.saveGoogleCredentials()
        runCurrent()

        assertEquals("Enter the matching Web application client secret for this Google client ID.", model.state.value.message)
        assertEquals("123-custom.apps.googleusercontent.com", store.values["googleDrive.clientID"])
        assertEquals(originalSecrets, store.secrets)
        assertEquals(setOf("googleDrive", "webDAV"), store.selected.value)
        assertEquals(0, model.state.value.googleCredentialsSavedRevision)

        model.update(SettingsField.GOOGLE_CLIENT_SECRET, "replacement-secret")
        model.saveGoogleCredentials()
        runCurrent()
        assertEquals("456-replacement.apps.googleusercontent.com", store.values["googleDrive.clientID"])
        assertEquals("replacement-secret", store.secrets["googleDrive.clientSecret"])
        assertNull(store.secrets["googleDrive.accessToken"])
        assertNull(store.secrets["googleDrive.expiresAt"])
        assertNull(store.secrets["googleDrive.refreshToken"])
        assertNull(store.secrets["googleDrive.refreshTokenClientID"])
        assertNull(store.secrets["googleDrive.accessTokenGrant"])
        assertEquals("dropbox-token", store.secrets["dropbox.accessToken"])
        assertEquals("webdav-password", store.secrets["webdav.password"])
        assertEquals("dropbox-id", store.values["dropbox.appKey"])
        assertEquals(setOf("webDAV"), store.selected.value)
    }

    @Test fun replacingGoogleSecretInvalidatesTokensEvenWhenClientIdStaysTheSame() = runTest {
        val store = FakeSettingsStore().apply { existingGoogleConnection() }
        val model = SettingsViewModel(store, backgroundScope)
        runCurrent()
        model.update(SettingsField.GOOGLE_CLIENT_SECRET, "replacement-secret")
        model.saveGoogleCredentials()
        runCurrent()

        assertEquals("replacement-secret", store.secrets["googleDrive.clientSecret"])
        assertNull(store.secrets["googleDrive.accessToken"])
        assertNull(store.secrets["googleDrive.refreshToken"])
        assertEquals(setOf("webDAV"), store.selected.value)
    }

    @Test fun rejectsInvalidGoogleClientIdAndCustomIdWithoutSecretWithoutChangingSavedConnection() = runTest {
        val store = FakeSettingsStore().apply { existingGoogleConnection() }
        val originalSecrets = store.secrets.toMap()
        val model = SettingsViewModel(store, backgroundScope)
        runCurrent()
        model.update(SettingsField.GOOGLE_CLIENT_ID, "invalid-client")
        model.update(SettingsField.GOOGLE_CLIENT_SECRET, "replacement-secret")
        model.saveGoogleCredentials()
        runCurrent()
        assertEquals("Enter a Google OAuth client ID ending in .apps.googleusercontent.com.", model.state.value.message)
        assertEquals(originalSecrets, store.secrets)
        assertEquals(setOf("googleDrive", "webDAV"), store.selected.value)

        val emptyStore = FakeSettingsStore()
        val emptyModel = SettingsViewModel(emptyStore, backgroundScope)
        runCurrent()
        emptyModel.update(SettingsField.GOOGLE_CLIENT_ID, "123-custom.apps.googleusercontent.com")
        emptyModel.saveGoogleCredentials()
        runCurrent()
        assertEquals("Enter the matching Web application client secret for this Google client ID.", emptyModel.state.value.message)
        assertTrue(emptyStore.values.isEmpty())
        assertTrue(emptyStore.secrets.isEmpty())
    }

    @Test fun blankGoogleFieldsKeepNativeSignInAndClearingCustomIdResetsOnlyGoogle() = runTest {
        val nativeStore = FakeSettingsStore().apply {
            secrets["googleDrive.accessToken"] = "native-token"
            selected.value = setOf("googleDrive")
        }
        val native = SettingsViewModel(nativeStore, backgroundScope)
        runCurrent()
        native.saveGoogleCredentials()
        runCurrent()
        assertEquals("native-token", nativeStore.secrets["googleDrive.accessToken"])
        assertEquals(setOf("googleDrive"), nativeStore.selected.value)

        val customStore = FakeSettingsStore().apply { existingGoogleConnection() }
        val custom = SettingsViewModel(customStore, backgroundScope)
        runCurrent()
        custom.update(SettingsField.GOOGLE_CLIENT_ID, "")
        custom.saveGoogleCredentials()
        runCurrent()
        assertEquals("", customStore.values["googleDrive.clientID"])
        assertTrue(customStore.secrets.isEmpty())
        assertEquals(setOf("webDAV"), customStore.selected.value)
    }

    @Test fun secretWithoutGoogleClientIdDoesNotOverwriteNativeConfiguration() = runTest {
        val store = FakeSettingsStore()
        val model = SettingsViewModel(store, backgroundScope)
        runCurrent()
        model.update(SettingsField.GOOGLE_CLIENT_SECRET, "unmatched-secret")
        model.saveGoogleCredentials()
        runCurrent()

        assertTrue(model.state.value.message!!.contains("clear both fields"))
        assertTrue(store.values.isEmpty())
        assertTrue(store.secrets.isEmpty())
        assertEquals(0, model.state.value.googleCredentialsSavedRevision)
    }

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
        var beforeGoogleSet: (suspend () -> Unit)? = null
        var googleSetCalls = 0
        override val selectedProviders = selected
        override val folderName = MutableStateFlow("")
        override suspend fun get(key: String) = values[key]
        override fun getSecret(key: String) = secrets[key]
        override suspend fun set(key: String, value: String) {
            if (key == "googleDrive.clientID") {
                googleSetCalls += 1
                beforeGoogleSet?.invoke()
            }
            values[key] = value
        }
        override fun setSecret(key: String, value: String) { secrets[key] = value }
        override fun removeSecret(key: String) { secrets.remove(key) }
        override suspend fun selectProvider(id: String, selected: Boolean) {
            this.selected.value = this.selected.value.toMutableSet().apply { if (selected) add(id) else remove(id) }
        }
        fun existingGoogleConnection() {
            values["googleDrive.clientID"] = "123-custom.apps.googleusercontent.com"
            secrets["googleDrive.clientSecret"] = "saved-secret"
            secrets["googleDrive.accessToken"] = "saved-access"
            secrets["googleDrive.expiresAt"] = "9999999999"
            secrets["googleDrive.refreshToken"] = "saved-refresh"
            secrets["googleDrive.refreshTokenClientID"] = "123-custom.apps.googleusercontent.com"
            secrets["googleDrive.accessTokenGrant"] = "old-client-grant-binding"
            selected.value = setOf("googleDrive", "webDAV")
        }
    }
}
