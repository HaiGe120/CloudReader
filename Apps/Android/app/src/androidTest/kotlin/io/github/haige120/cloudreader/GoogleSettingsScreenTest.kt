package io.github.haige120.cloudreader

import android.app.Activity
import android.content.ContextWrapper
import android.graphics.Bitmap
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.test.core.app.ApplicationProvider
import io.github.haige120.cloudreader.ui.CloudReaderTheme
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.MutableStateFlow
import org.junit.Rule
import org.junit.Test
import java.io.File

/** Production settings screen with in-memory services; run only on a disposable emulator. */
class GoogleSettingsScreenTest {
    @get:Rule val compose = createComposeRule()

    @Test fun lightSettingsNeedsOnlyConnectAndKeepsCredentialsAdvanced() = verify(false)
    @Test fun darkSettingsNeedsOnlyConnectAndKeepsCredentialsAdvanced() = verify(true)

    private fun verify(dark: Boolean) {
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
        val store = object : SettingsStore {
            override val selectedProviders = MutableStateFlow(emptySet<String>())
            override val folderName = MutableStateFlow("")
            private val values = mutableMapOf<String, String>()
            private val secrets = mutableMapOf<String, String>()
            override suspend fun get(key: String) = values[key]
            override fun getSecret(key: String) = secrets[key]
            override suspend fun set(key: String, value: String) { values[key] = value }
            override fun setSecret(key: String, value: String) { secrets[key] = value }
            override fun removeSecret(key: String) { secrets.remove(key) }
            override suspend fun selectProvider(id: String, selected: Boolean) {
                selectedProviders.value = selectedProviders.value.toMutableSet().apply { if (selected) add(id) else remove(id) }
            }
        }
        val model = SettingsViewModel(store, scope)
        val app = ApplicationProvider.getApplicationContext<CloudReaderApp>()
        try {
            compose.setContent {
                val activity = generateSequence(LocalContext.current) { (it as? ContextWrapper)?.baseContext }.filterIsInstance<Activity>().first()
                CloudReaderTheme(darkTheme = dark) {
                    Surface(color = MaterialTheme.colorScheme.background, contentColor = MaterialTheme.colorScheme.onBackground) {
                        Box(Modifier.fillMaxSize().testTag("real-settings-screen")) {
                            SettingsScreen(activity, app, {}, GoogleDriveConnectionState(), {}, {}, settingsModel = model)
                        }
                    }
                }
            }
            compose.onNodeWithText("Connect", useUnmergedTree = true).assertIsDisplayed().assertIsEnabled()
            compose.onNodeWithText("Google OAuth client ID (Web application)").assertDoesNotExist()
            compose.onNodeWithText("Google OAuth client secret").assertDoesNotExist()
            val file = File(app.cacheDir, "auth-readability/real-settings-${if(dark)"dark"else"light"}.png")
            file.parentFile!!.mkdirs()
            file.outputStream().use { compose.onNodeWithTag("real-settings-screen").captureToImage().asAndroidBitmap().compress(Bitmap.CompressFormat.PNG, 100, it) }
            compose.onNodeWithText("Advanced Google settings (optional)").performScrollTo().performClick()
            compose.onNodeWithText("Google OAuth client ID (Web application)").assertDoesNotExist()
            val switch = compose.onNode(isToggleable() and SemanticsMatcher.expectValue(SemanticsProperties.Role, Role.Switch))
            switch.performScrollTo().assertIsOff().performClick()
            compose.onNodeWithText("Google OAuth client ID (Web application)").performScrollTo().assertIsDisplayed()
            compose.onNodeWithText("Google OAuth client secret").performScrollTo().assertIsDisplayed()
            switch.performScrollTo().performClick().assertIsOff()
            compose.onNodeWithText("Google OAuth client ID (Web application)").assertDoesNotExist()
            compose.onNodeWithText("Google OAuth client secret").assertDoesNotExist()
        } finally { scope.cancel() }
    }
}
