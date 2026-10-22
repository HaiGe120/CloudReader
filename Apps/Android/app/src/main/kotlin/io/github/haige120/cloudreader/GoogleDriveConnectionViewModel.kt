package io.github.haige120.cloudreader

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

data class GoogleDriveConnectionState(
    val busy: Boolean = false,
    val message: String? = null,
)

/** Keeps the connection pending while Google's account and consent screens are open. */
class GoogleDriveConnectionViewModel(
    private val saveToken: suspend (String) -> Unit,
    stateScope: CoroutineScope? = null,
) : ViewModel() {
    private val scope = stateScope ?: viewModelScope
    private val mutableState = MutableStateFlow(GoogleDriveConnectionState())
    val state: StateFlow<GoogleDriveConnectionState> = mutableState.asStateFlow()

    fun connect(start: (onToken: (String) -> Unit, onError: (Throwable) -> Unit) -> Unit) {
        if (mutableState.value.busy) return
        mutableState.value = GoogleDriveConnectionState(busy = true)
        try {
            start(::acceptToken, ::fail)
        } catch (error: Exception) {
            fail(error)
        }
    }

    fun complete(cancelled: Boolean, hasData: Boolean, readToken: () -> String) {
        // Google can return a detailed provider error in a non-OK result intent.
        // Activity-result delivery may also follow process or Activity recreation.
        if (hasData) {
            mutableState.value = GoogleDriveConnectionState(busy = true)
            try {
                acceptToken(readToken())
            } catch (error: Exception) {
                fail(error)
            }
        } else {
            mutableState.value = GoogleDriveConnectionState(
                message = if (cancelled) {
                    "Google Drive connection cancelled."
                } else {
                    "Google Drive did not return a sign-in result. Please try again."
                },
            )
        }
    }

    fun fail(error: Throwable) {
        if (error is CancellationException) {
            mutableState.update { it.copy(busy = false) }
            throw error
        }
        mutableState.value = GoogleDriveConnectionState(
            message = error.localizedMessage?.takeIf { it.isNotBlank() }
                ?: "Google Drive connection failed. Please try again.",
        )
    }

    fun consumeMessage() {
        mutableState.update { it.copy(message = null) }
    }

    private fun acceptToken(token: String) {
        if (token.isBlank()) {
            fail(IllegalStateException("Google Drive did not return an access token. Please try again."))
            return
        }
        mutableState.value = GoogleDriveConnectionState(busy = true)
        scope.launch {
            try {
                saveToken(token)
                mutableState.value = GoogleDriveConnectionState(message = "Google Drive connected")
            } catch (error: Exception) {
                fail(error)
            }
        }
    }
}
