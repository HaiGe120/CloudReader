package io.github.haige120.cloudreader

import android.app.Application
import io.github.haige120.cloudreader.ai.AIService
import io.github.haige120.cloudreader.data.CloudReaderDatabase
import io.github.haige120.cloudreader.data.CloudReaderPreferences
import io.github.haige120.cloudreader.data.LibraryRepository
import io.github.haige120.cloudreader.data.SecureVault
import io.github.haige120.cloudreader.sync.SyncEngine
import io.github.haige120.cloudreader.sync.SyncOutcome
import io.github.haige120.cloudreader.sync.OAuthConnector
import io.github.haige120.cloudreader.sync.SyncTrigger
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.collect
import io.github.haige120.cloudreader.sync.afterInitialDistinct

class CloudReaderApp : Application() {
    val applicationScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    val database by lazy { CloudReaderDatabase.get(this) }
    val library by lazy { LibraryRepository(this, database.libraryDao()) }
    val preferences by lazy { CloudReaderPreferences(this) }
    val vault by lazy { SecureVault(this) }
    val ai by lazy { AIService(vault) }
    val sync by lazy {
        SyncEngine(this, database.libraryDao(), library, preferences, vault) {
            OAuthConnector(this, preferences, vault).refreshGoogleToken()
        }
    }
    val syncOutcome = MutableStateFlow<SyncOutcome?>(null)
    val ready = CompletableDeferred<Unit>()

    override fun onCreate() {
        super.onCreate()
        applicationScope.launch {
            preferences.selectedProviders.afterInitialDistinct().collect {
                applicationScope.launch { requestSync(SyncTrigger.PROVIDER_SELECTION) }
            }
        }
        applicationScope.launch {
            runCatching { library.seedDemoBook() }
            ready.complete(Unit)
        }
    }

    suspend fun requestSync(trigger: SyncTrigger): SyncOutcome {
        ready.await()
        return sync.request(trigger).also { syncOutcome.value = it }
    }
}
