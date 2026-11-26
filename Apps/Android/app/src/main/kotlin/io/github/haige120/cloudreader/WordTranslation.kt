package io.github.haige120.cloudreader

import android.app.AlertDialog
import android.content.Context
import android.content.ContextWrapper
import android.icu.util.ULocale
import android.os.CancellationSignal
import android.view.Menu
import android.view.translation.*
import androidx.activity.ComponentActivity
import androidx.lifecycle.lifecycleScope
import java.util.Locale
import kotlin.coroutines.resume
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull

internal object WordTranslation {
    const val MENU_ID = 19302
    private val englishWord = Regex("[A-Za-z]+(?:[-'’][A-Za-z]+)*")

    fun addAction(context: Context, menu: Menu) {
        val activity = readerActivity(context) ?: return
        val app = activity.application as? CloudReaderApp ?: return
        activity.lifecycleScope.launch {
            if (app.preferences.getBool("reader.translateWords") && menu.findItem(MENU_ID) == null) {
                menu.add(0, MENU_ID, 101, "Translate word")
            }
        }
    }

    suspend fun targets(context: Context): List<String> = withContext(Dispatchers.IO) {
        val manager = context.getSystemService(TranslationManager::class.java) ?: return@withContext emptyList()
        val text = TranslationSpec.DATA_FORMAT_TEXT
        manager.getOnDeviceTranslationCapabilities(text, text)
            .filter { it.sourceSpec.locale.language == "en" && it.targetSpec.locale.language != "en" &&
                it.state == TranslationCapability.STATE_ON_DEVICE }
            .map { it.targetSpec.locale.toLanguageTag() }.distinct().sorted()
    }

    fun show(context: Context, selection: String) {
        val activity = readerActivity(context) ?: return
        val app = activity.application as? CloudReaderApp ?: return
        activity.lifecycleScope.launch {
            if (!app.preferences.getBool("reader.translateWords")) return@launch
            val word = selection.trim()
            val result = try {
                require(word.length <= 100 && englishWord.matches(word)) { "Select one English word to translate." }
                val target = app.preferences.get("reader.translationTarget") ?: Locale.getDefault().toLanguageTag()
                val available = targets(activity)
                val language = Locale.forLanguageTag(target).language
                val match = available.firstOrNull { it.equals(target, true) }
                    ?: available.firstOrNull { Locale.forLanguageTag(it).language == language }
                    ?: error("Choose an installed translation language in Reading settings.")
                withTimeoutOrNull(15_000) { translate(activity, word, match) } ?: error("Translation timed out.")
            } catch (cancelled: CancellationException) { throw cancelled }
            catch (failure: Exception) { failure.localizedMessage ?: "Translation unavailable." }
            if (!activity.isFinishing && !activity.isDestroyed) {
                AlertDialog.Builder(activity).setTitle(word.take(100)).setMessage(result).setPositiveButton("Close", null).show()
            }
        }
    }

    private suspend fun translate(activity: ComponentActivity, word: String, target: String): String {
        val manager = activity.getSystemService(TranslationManager::class.java) ?: error("Translation unavailable.")
        val text = TranslationSpec.DATA_FORMAT_TEXT
        val context = TranslationContext.Builder(TranslationSpec(ULocale.ENGLISH, text),
            TranslationSpec(ULocale.forLanguageTag(target), text)).build()
        val translator = suspendCancellableCoroutine<Translator?> { continuation ->
            manager.createOnDeviceTranslator(context, activity.mainExecutor) { value ->
                continuation.resume(value) { _, resource, _ -> resource?.destroy() }
            }
        } ?: error("The translation service is unavailable.")
        try {
            val request = TranslationRequest.Builder()
                .setTranslationRequestValues(listOf(TranslationRequestValue.forText(word))).build()
            val result = suspendCancellableCoroutine<String?> { continuation ->
                val signal = CancellationSignal()
                continuation.invokeOnCancellation { signal.cancel() }
                translator.translate(request, signal, activity.mainExecutor) { result ->
                    if (continuation.isActive) continuation.resume(result.translationResponseValues[0]?.text?.toString())
                }
            }
            return result?.takeIf(String::isNotBlank) ?: error("No translation available for this word.")
        } finally { translator.destroy() }
    }
}

internal fun readerActivity(context: Context): ComponentActivity? {
    var current = context
    while (current is ContextWrapper) {
        if (current is ComponentActivity) return current
        current = current.baseContext
    }
    return null
}
