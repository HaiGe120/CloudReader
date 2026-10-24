package io.github.haige120.cloudreader

import android.app.Dialog
import android.content.res.Configuration
import android.os.Bundle
import android.widget.Toast
import androidx.appcompat.app.AppCompatActivity
import androidx.fragment.app.commitNow
import androidx.lifecycle.lifecycleScope
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import org.readium.r2.navigator.epub.EpubNavigatorFactory
import org.readium.r2.navigator.epub.EpubNavigatorFragment
import org.readium.r2.navigator.epub.css.RsProperties
import org.readium.r2.navigator.input.InputListener
import org.readium.r2.navigator.input.TapEvent
import org.readium.r2.navigator.util.DirectionalNavigationAdapter
import org.readium.r2.shared.ExperimentalReadiumApi
import org.readium.r2.shared.publication.Locator
import org.readium.r2.shared.publication.Publication

/** Native reader wiring, with storage callbacks injected for isolated real-publication tests. */
@OptIn(ExperimentalReadiumApi::class)
internal class EpubReaderHost(
    private val activity: AppCompatActivity,
    private val chrome: NativeReaderChrome,
    private val containerId: Int,
    private val onSettingChanged: suspend (String, String) -> Unit,
    private val onLocatorChanged: suspend (Locator) -> Unit,
) {
    var navigator: EpubNavigatorFragment? = null
        private set
    var appearance: EpubReaderAppearance = EpubReaderAppearance()
        private set
    private var locatorJob: Job? = null
    private var appearanceDialog: Dialog? = null
    private val settingsMutex = Mutex()
    private var closed = false

    fun attach(publication: Publication, initialLocator: Locator?, appearance: EpubReaderAppearance) {
        check(navigator == null && !closed)
        this.appearance = appearance
        val factory = EpubNavigatorFactory(publication).createFragmentFactory(
            initialLocator = initialLocator,
            initialPreferences = appearance.toReadiumPreferences(systemDark(), wideScreen()),
            configuration = EpubNavigatorFragment.Configuration(
                readiumCssRsProperties = RsProperties(
                    // Readium's default CSS waits until 60em before allowing two columns.
                    // Use our explicit adaptive preference on unfolded phones too; its
                    // scrolling styles still disable columns in scrolling mode.
                    overrides = mapOf(
                        "--RS__colCount" to "var(--USER__colCount, 1)",
                        "--RS__colWidth" to "auto",
                    ),
                ),
            ),
        )
        activity.supportFragmentManager.fragmentFactory = factory
        activity.supportFragmentManager.commitNow {
            replace(containerId, EpubNavigatorFragment::class.java, Bundle(), NAVIGATOR_TAG)
        }
        val reader = activity.supportFragmentManager.findFragmentByTag(NAVIGATOR_TAG) as EpubNavigatorFragment
        navigator = reader
        // Readium handles links and selections before dispatching unhandled publication taps.
        reader.addInputListener(object : InputListener {
            override fun onTap(event: TapEvent): Boolean {
                val surface = reader.publicationView
                if (!isReaderChromeCenterTap(event.point.x, surface.width) ||
                    event.point.y <= surface.height * 0.25f || event.point.y >= surface.height * 0.75f
                ) return false
                chrome.toggleControls()
                return true
            }
        })
        reader.addInputListener(DirectionalNavigationAdapter(reader))
        chrome.setAppearanceAction { showAppearance() }
        applyColors()
        // No floating recovery control covers the publication. Center taps and accessibility
        // actions restore the shell, while edge taps retain Readium navigation.
        chrome.setControlsVisible(false)
        locatorJob = activity.lifecycleScope.launch {
            reader.currentLocator.collect { locator ->
                if (!closed) onLocatorChanged(locator)
            }
        }
    }

    fun applyAppearance(appearance: EpubReaderAppearance) {
        if (closed) return
        this.appearance = appearance
        // Readium keeps its current locator while reflowing to the new preferences.
        navigator?.submitPreferences(appearance.toReadiumPreferences(systemDark(), wideScreen()))
        applyColors()
    }

    private fun showAppearance() {
        if (closed || activity.isFinishing || activity.isDestroyed) return
        appearanceDialog?.dismiss()
        appearanceDialog = showEpubAppearanceDialog(activity, appearance) { key, value ->
            activity.lifecycleScope.launch {
                settingsMutex.withLock {
                    if (closed) return@withLock
                    try {
                        onSettingChanged(key, value)
                        applyAppearance(appearance.updated(key, value))
                    } catch (cancelled: CancellationException) {
                        throw cancelled
                    } catch (_: Exception) {
                        appearanceDialog?.dismiss()
                        Toast.makeText(activity, "Could not save reading settings. Please try again.", Toast.LENGTH_LONG).show()
                    }
                }
            }
        }
    }

    fun close() {
        closed = true
        appearanceDialog?.dismiss()
        appearanceDialog = null
        locatorJob?.cancel()
        locatorJob = null
        navigator = null
    }

    private fun applyColors() {
        val colors = appearance.palette(systemDark())
        chrome.setReadingColors(colors.background, colors.foreground, colors.muted)
    }

    private fun systemDark(): Boolean =
        activity.resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK == Configuration.UI_MODE_NIGHT_YES

    private fun wideScreen(): Boolean = activity.resources.configuration.screenWidthDp >= 600

    companion object { private const val NAVIGATOR_TAG = "epub-navigator" }
}
