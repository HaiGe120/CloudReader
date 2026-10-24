package io.github.haige120.cloudreader

import android.app.Dialog
import android.content.res.Configuration
import android.graphics.Typeface
import android.graphics.drawable.ColorDrawable
import android.graphics.drawable.GradientDrawable
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.view.Window
import android.widget.HorizontalScrollView
import android.widget.LinearLayout
import android.widget.RadioGroup
import android.widget.ScrollView
import android.widget.TextView
import androidx.appcompat.app.AppCompatDialog
import androidx.appcompat.widget.AppCompatButton
import androidx.appcompat.widget.AppCompatRadioButton
import androidx.core.view.ViewCompat
import androidx.fragment.app.FragmentActivity

/** A native, scrollable panel. Each change applies immediately without dismissing it. */
internal fun showEpubAppearanceDialog(
    activity: FragmentActivity,
    appearance: EpubReaderAppearance,
    onChanged: (String, String) -> Unit,
): Dialog {
    val dialog = AppCompatDialog(activity)
    dialog.supportRequestWindowFeature(Window.FEATURE_NO_TITLE)
    val density = activity.resources.displayMetrics.density
    fun dp(value: Int) = (value * density).toInt()
    var current = appearance
    val isNight = activity.resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK == Configuration.UI_MODE_NIGHT_YES
    val paper = if (isNight) 0xFF232322.toInt() else 0xFFFFFDF8.toInt()
    val ink = if (isNight) 0xFFE5E1D8.toInt() else 0xFF292621.toInt()

    fun label(text: String, size: Float = 14f): TextView = TextView(activity).apply {
        this.text = text
        textSize = size
        setTextColor(ink)
    }
    val panel = LinearLayout(activity).apply {
        orientation = LinearLayout.VERTICAL
        setPadding(dp(20), dp(12), dp(20), dp(16))
        background = GradientDrawable().apply { setColor(paper); cornerRadius = dp(24).toFloat() }
    }
    val header = LinearLayout(activity).apply { gravity = Gravity.CENTER_VERTICAL }
    val title = label("Reading appearance", 20f).apply { setTypeface(Typeface.SERIF, Typeface.BOLD) }
    ViewCompat.setAccessibilityHeading(title, true)
    header.addView(title, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
    header.addView(AppCompatButton(activity).apply {
        text = "Done"
        setOnClickListener { dialog.dismiss() }
    }, LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, dp(48)))
    panel.addView(header)

    val body = LinearLayout(activity).apply { orientation = LinearLayout.VERTICAL }
    val scroll = ScrollView(activity).apply {
        isFillViewport = true
        addView(body, ViewGroup.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT))
    }
    panel.addView(scroll, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f))

    fun section(text: String) {
        body.addView(label(text, 15f).apply {
            setTypeface(typeface, Typeface.BOLD)
            setPadding(0, dp(16), 0, dp(4))
            ViewCompat.setAccessibilityHeading(this, true)
        })
    }
    fun change(key: String, value: String) {
        current = current.updated(key, value)
        onChanged(key, value)
    }
    fun choices(options: List<Pair<String, String>>, selected: String, onSelected: (String) -> Unit): RadioGroup {
        val group = RadioGroup(activity).apply { orientation = RadioGroup.HORIZONTAL }
        options.forEach { (value, title) ->
            group.addView(AppCompatRadioButton(activity).apply {
                id = View.generateViewId()
                tag = value
                text = title
                contentDescription = title
                textSize = 14f
                minHeight = dp(48)
                setTextColor(ink)
                isChecked = value == selected
            }, RadioGroup.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT))
        }
        group.setOnCheckedChangeListener { radioGroup, checkedId ->
            radioGroup.findViewById<View>(checkedId)?.tag?.toString()?.let(onSelected)
        }
        body.addView(HorizontalScrollView(activity).apply {
            isHorizontalScrollBarEnabled = false
            addView(group)
        }, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT))
        return group
    }

    section("Page layout")
    choices(listOf("scroll" to "Scrolling", "single" to "One page", "facing" to "Two pages"), current.layout) {
        change(EpubReaderAppearance.LAYOUT_KEY, it)
    }
    body.addView(label("Two pages use wide screens and show one page on compact screens. Fixed-layout books keep their original typography.", 12f))

    section("Page color")
    val customColors = LinearLayout(activity).apply { orientation = LinearLayout.VERTICAL }
    choices(listOf("system" to "System", "light" to "Light", "sepia" to "Sepia", "dark" to "Dark", "custom" to "Custom"), current.theme) {
        change("reader.theme", it)
        customColors.visibility = if (it == "custom") View.VISIBLE else View.GONE
    }
    body.addView(customColors)
    customColors.visibility = if (current.theme == "custom") View.VISIBLE else View.GONE

    fun colorChoices(title: String, key: String, colors: List<String>, initial: String) {
        customColors.addView(label(title).apply { setPadding(0, dp(8), 0, 0) })
        val row = LinearLayout(activity)
        val buttons = mutableListOf<View>()
        fun refresh(selected: String) {
            buttons.forEach { button ->
                button.isSelected = button.tag == selected
                button.background = GradientDrawable().apply {
                    setColor(parseReaderHexColor(button.tag.toString(), paper))
                    cornerRadius = dp(12).toFloat()
                    setStroke(dp(if (button.isSelected) 3 else 1), if (button.isSelected) ink else 0xFF888888.toInt())
                }
            }
        }
        colors.forEach { color ->
            val swatch = AppCompatButton(activity).apply {
                tag = color
                contentDescription = "$title $color"
                setOnClickListener { change(key, color); refresh(color) }
            }
            buttons += swatch
            row.addView(swatch, LinearLayout.LayoutParams(dp(48), dp(48)).apply { marginEnd = dp(8) })
        }
        refresh(initial)
        customColors.addView(HorizontalScrollView(activity).apply {
            isHorizontalScrollBarEnabled = false
            addView(row)
        })
    }
    colorChoices("Paper", "reader.customBackground", listOf("#F8F4EB", "#FFFEF8", "#E6E8D8", "#F2DEC2", "#232322"), current.customBackground.ifEmpty { "#F8F4EB" })
    colorChoices("Ink", "reader.customForeground", listOf("#292621", "#3C332A", "#1D3A2A", "#F2EFE8", "#FFFFFF"), current.customForeground.ifEmpty { "#292621" })

    section("Typography")
    choices(listOf("serif" to "Serif", "sans" to "Sans", "mono" to "Mono"), current.font) { change("reader.font", it) }
    val sizeRow = LinearLayout(activity).apply { gravity = Gravity.CENTER_VERTICAL }
    sizeRow.addView(label("Text size"), LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
    val sizeValue = label("${current.fontSize} pt").apply {
        gravity = Gravity.CENTER
        accessibilityLiveRegion = View.ACCESSIBILITY_LIVE_REGION_POLITE
    }
    lateinit var smaller: AppCompatButton
    lateinit var larger: AppCompatButton
    fun refreshSize() {
        sizeValue.text = "${current.fontSize} pt"
        smaller.isEnabled = current.fontSize > 14
        larger.isEnabled = current.fontSize < 38
    }
    smaller = AppCompatButton(activity).apply {
        text = "−"
        contentDescription = "Smaller text"
        setOnClickListener { change("reader.fontSize", (current.fontSize - 1).coerceAtLeast(14).toString()); refreshSize() }
    }
    larger = AppCompatButton(activity).apply {
        text = "+"
        contentDescription = "Larger text"
        setOnClickListener { change("reader.fontSize", (current.fontSize + 1).coerceAtMost(38).toString()); refreshSize() }
    }
    sizeRow.addView(smaller, LinearLayout.LayoutParams(dp(48), dp(48)))
    sizeRow.addView(sizeValue, LinearLayout.LayoutParams(dp(62), dp(48)))
    sizeRow.addView(larger, LinearLayout.LayoutParams(dp(48), dp(48)))
    refreshSize()
    body.addView(sizeRow)
    body.addView(label("Typography and page colors also apply to text books.", 12f))

    dialog.setContentView(panel)
    dialog.show()
    dialog.window?.apply {
        setBackgroundDrawable(ColorDrawable(android.graphics.Color.TRANSPARENT))
        setGravity(Gravity.BOTTOM or Gravity.CENTER_HORIZONTAL)
        setLayout(
            minOf(activity.resources.displayMetrics.widthPixels - dp(24), dp(640)),
            minOf((activity.resources.displayMetrics.heightPixels * 0.82f).toInt(), dp(640)),
        )
    }
    return dialog
}
