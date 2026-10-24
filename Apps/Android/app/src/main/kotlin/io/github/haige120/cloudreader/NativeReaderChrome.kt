package io.github.haige120.cloudreader

import android.app.Activity
import android.graphics.Rect
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.text.TextUtils
import android.view.GestureDetector
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.view.ViewGroup
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.TextView
import androidx.core.graphics.ColorUtils
import androidx.core.view.ViewCompat
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import kotlin.math.roundToInt

/** A small native shell shared by the PDF and Readium hosts. Hiding it releases its layout space. */
internal class NativeReaderChrome(
    private val activity: Activity,
    containerId: Int,
    private val showRestoreControl: Boolean = true,
    private val immersiveSystemBars: Boolean = false,
) {
    private var foregroundColor = INK
    private var controlsAccessibilityAction: Int? = null
    val root = FrameLayout(activity).apply { setBackgroundColor(PAPER) }
    val content = FrameLayout(activity).apply { id = containerId }
    private val column = LinearLayout(activity).apply { orientation = LinearLayout.VERTICAL }
    private val toolbar = LinearLayout(activity).apply {
        orientation = LinearLayout.HORIZONTAL
        gravity = Gravity.CENTER_VERTICAL
        setPadding(dp(4), 0, dp(4), 0)
        setBackgroundColor(PAPER)
    }
    private val title = TextView(activity).apply {
        textSize = 16f
        typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL)
        setTextColor(INK)
        setSingleLine()
        ellipsize = TextUtils.TruncateAt.END
        setPadding(dp(4), 0, dp(8), 0)
    }
    private val progress = TextView(activity).apply {
        textSize = 12f
        setTextColor(MUTED)
        setSingleLine()
        setPadding(0, 0, dp(4), 0)
    }
    private val selectionAction = action("AI", "Ask AI about selection").apply { visibility = View.GONE }
    private val appearanceAction = action("Aa", "Reading appearance").apply {
        textSize = 18f
        visibility = View.GONE
    }
    private val restore = action("Show controls", "Show reading controls").apply {
        textSize = 12f
        minimumWidth = dp(112)
        setPadding(dp(12), 0, dp(12), 0)
        background = GradientDrawable().apply {
            setColor(PAPER)
            cornerRadius = dp(24).toFloat()
            setStroke(dp(1), 0xFFD9D3C7.toInt())
        }
        elevation = dp(3).toFloat()
        setOnClickListener { setControlsVisible(true) }
    }

    var controlsVisible: Boolean = true
        private set

    init {
        // Android 17 requires the decor to exist before resolving its insets controller.
        val decorView = activity.window.decorView
        WindowCompat.setDecorFitsSystemWindows(activity.window, false)
        val controller = WindowCompat.getInsetsController(activity.window, decorView)
        controller.isAppearanceLightStatusBars = true
        controller.isAppearanceLightNavigationBars = true
        controller.systemBarsBehavior = WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
        ViewCompat.setOnApplyWindowInsetsListener(root) { view, insets ->
            val safe = insets.getInsets(WindowInsetsCompat.Type.systemBars() or WindowInsetsCompat.Type.displayCutout())
            view.setPadding(safe.left, safe.top, safe.right, safe.bottom)
            insets
        }
        toolbar.addView(action("‹", "Back to library").apply {
            textSize = 32f
            setOnClickListener { activity.finish() }
        }, LinearLayout.LayoutParams(dp(48), dp(48)))
        toolbar.addView(title, LinearLayout.LayoutParams(0, dp(48), 1f))
        title.gravity = Gravity.CENTER_VERTICAL
        toolbar.addView(progress, LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT))
        toolbar.addView(selectionAction, LinearLayout.LayoutParams(dp(48), dp(48)))
        toolbar.addView(appearanceAction, LinearLayout.LayoutParams(dp(48), dp(48)))
        toolbar.addView(action("⌄", "Hide reading controls").apply {
            textSize = 24f
            setOnClickListener { setControlsVisible(false) }
        }, LinearLayout.LayoutParams(dp(48), dp(48)))
        column.addView(toolbar, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, dp(52)))
        column.addView(content, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f))
        root.addView(column, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
        if (showRestoreControl) {
            root.addView(restore, FrameLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, dp(48), Gravity.TOP or Gravity.END).apply {
                topMargin = dp(8)
                marginEnd = dp(12)
            })
        }
        root.importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_YES
        setControlsVisible(true)
    }

    fun setTitle(value: String) {
        title.text = value
        title.contentDescription = value
    }

    fun setProgress(value: String, description: String = value) {
        progress.text = value
        progress.contentDescription = description
    }

    fun setSelectionAction(available: Boolean, onClick: () -> Unit) {
        selectionAction.visibility = if (available) View.VISIBLE else View.GONE
        selectionAction.setOnClickListener { onClick() }
    }

    fun setAppearanceAction(onClick: () -> Unit) {
        appearanceAction.visibility = View.VISIBLE
        appearanceAction.setOnClickListener { onClick() }
    }

    fun setReadingColors(background: Int, foreground: Int, muted: Int) {
        foregroundColor = foreground
        root.setBackgroundColor(background)
        content.setBackgroundColor(background)
        toolbar.setBackgroundColor(background)
        for (index in 0 until toolbar.childCount) {
            (toolbar.getChildAt(index) as? TextView)?.setTextColor(foreground)
        }
        progress.setTextColor(muted)
        restore.setTextColor(foreground)
        (restore.background as? GradientDrawable)?.apply {
            setColor(background)
            setStroke(dp(1), ColorUtils.setAlphaComponent(muted, 100))
        }
        for (index in 0 until content.childCount) {
            (content.getChildAt(index) as? TextView)?.setTextColor(foreground)
        }
        val controller = WindowCompat.getInsetsController(activity.window, root)
        val lightBackground = ColorUtils.calculateLuminance(background) > 0.5
        controller.isAppearanceLightStatusBars = lightBackground
        controller.isAppearanceLightNavigationBars = lightBackground
    }

    fun setControlsVisible(visible: Boolean) {
        controlsVisible = visible
        toolbar.visibility = if (visible) View.VISIBLE else View.GONE
        restore.visibility = if (showRestoreControl && !visible) View.VISIBLE else View.GONE
        val controller = WindowCompat.getInsetsController(activity.window, root)
        val bars = if (immersiveSystemBars) WindowInsetsCompat.Type.systemBars() else WindowInsetsCompat.Type.statusBars()
        if (visible) controller.show(bars) else controller.hide(bars)
        controlsAccessibilityAction?.let { ViewCompat.removeAccessibilityAction(root, it) }
        controlsAccessibilityAction = ViewCompat.addAccessibilityAction(
            root,
            if (visible) "Hide reading controls" else "Show reading controls",
        ) { _, _ ->
            setControlsVisible(!controlsVisible)
            true
        }
        ViewCompat.requestApplyInsets(root)
    }

    fun toggleControls() = setControlsVisible(!controlsVisible)

    fun showError(message: String) {
        content.addView(TextView(activity).apply {
            text = message
            textSize = 16f
            setTextColor(foregroundColor)
            gravity = Gravity.CENTER
            setPadding(dp(24), dp(24), dp(24), dp(24))
        }, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
        setControlsVisible(true)
    }

    /** Overlay controls and system insets must never count as publication taps. */
    fun containsContentPoint(rawX: Float, rawY: Float): Boolean =
        content.containsScreenPoint(rawX, rawY) && (!showRestoreControl || !restore.containsScreenPoint(rawX, rawY))

    private fun action(label: String, description: String) = TextView(activity).apply {
        text = label
        textSize = 16f
        gravity = Gravity.CENTER
        minimumWidth = dp(48)
        minimumHeight = dp(48)
        setTextColor(INK)
        contentDescription = description
        tooltipText = description
        isFocusable = true
        isClickable = true
        val attributes = activity.obtainStyledAttributes(intArrayOf(android.R.attr.selectableItemBackgroundBorderless))
        background = attributes.getDrawable(0)
        attributes.recycle()
    }

    private fun dp(value: Int): Int = (value * activity.resources.displayMetrics.density).roundToInt()

    private fun View.containsScreenPoint(x: Float, y: Float): Boolean {
        val bounds = Rect()
        return isShown && getGlobalVisibleRect(bounds) && bounds.contains(x.toInt(), y.toInt())
    }

    companion object {
        private const val PAPER = 0xFFF7F3E9.toInt()
        private const val INK = 0xFF292621.toInt()
        private const val MUTED = 0xFF6C675E.toInt()
    }
}

/** Observe native PDF gestures without taking their touch listener or consuming any event. */
internal class ReaderContentTapObserver(
    activity: Activity,
    private val canStartTap: (MotionEvent) -> Boolean,
    private val canFinishTap: () -> Boolean,
    onTap: () -> Unit,
) {
    private var eligible = false
    private val detector = GestureDetector(activity, object : GestureDetector.SimpleOnGestureListener() {
        override fun onDown(event: MotionEvent): Boolean = true

        override fun onSingleTapConfirmed(event: MotionEvent): Boolean {
            if (eligible && canFinishTap()) onTap()
            return false
        }
    })

    fun observe(event: MotionEvent) {
        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN -> eligible = canStartTap(event)
            MotionEvent.ACTION_POINTER_DOWN, MotionEvent.ACTION_CANCEL -> eligible = false
        }
        // The result is deliberately ignored: PdfView still receives the complete original stream.
        detector.onTouchEvent(event)
    }
}

/** Readium reserves edge taps for page navigation. */
internal fun isReaderChromeCenterTap(x: Float, width: Int, minimumEdgeSize: Float = 80f): Boolean {
    if (width <= 0 || !x.isFinite()) return false
    val edge = maxOf(minimumEdgeSize, width * 0.3f)
    return x > edge && x < width - edge
}
