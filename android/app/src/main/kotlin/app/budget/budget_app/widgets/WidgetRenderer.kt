package app.budget.budget_app.widgets

import android.content.Context
import android.content.res.Configuration
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.Path
import android.graphics.RectF
import android.graphics.Typeface
import app.budget.budget_app.R
import org.json.JSONObject
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import kotlin.math.ceil
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt
import kotlin.math.sqrt

/** «Тетрадь» colors; the widget follows the phone's light/dark mode at render time. */
private class Palette(
    val bg: Int, val ink: Int, val muted: Int, val rule: Int, val track: Int, val accent: Int,
    val good: Int, val bad: Int, val within: Int, val over: Int, val shade: Int, val area: Int,
    val btnBg: Int, val btnFg: Int,
) {
    companion object {
        private fun c(v: Long) = v.toInt()
        val LIGHT = Palette(
            c(0xFFFBF9F4), c(0xFF1B2422), c(0xFF5F5E57), c(0xFFDDD8CC), c(0xFFECE8DE), c(0xFF0E3B34),
            c(0xFF1F7A5C), c(0xFFB3261E), c(0xFFD5ECDF), c(0xFFFBE7B5), c(0xFFF3F0E8), c(0xFFBFE3D1),
            c(0xFF1B2422), c(0xFFFBF9F4),
        )
        val DARK = Palette(
            c(0xFF121816), c(0xFFEDEAE2), c(0xFFA3A69E), c(0xFF2E3633), c(0xFF242C29), c(0xFF7FD1AE),
            c(0xFF7FD1AE), c(0xFFF2A69D), c(0xFF1E3D33), c(0xFF4A3B17), c(0xFF1A211E), c(0xFF2F5A4C),
            c(0xFFEDEAE2), c(0xFF121816),
        )
        const val YELLOW = 0xFFF2C14E.toInt()

        fun of(ctx: Context): Palette {
            val night = ctx.resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK
            return if (night == Configuration.UI_MODE_NIGHT_YES) DARK else LIGHT
        }
    }
}

/** IBM Plex from the app's Flutter assets; system fonts if they can't be read. */
private object Fonts {
    private val cache = HashMap<String, Typeface>()

    fun get(ctx: Context, name: String, fallback: Typeface): Typeface = synchronized(cache) {
        cache.getOrPut(name) {
            runCatching { Typeface.createFromAsset(ctx.assets, "flutter_assets/assets/fonts/$name.ttf") }.getOrDefault(fallback)
        }
    }
}

/** Draws one widget into a bitmap. Coordinates are in dp; [w]×[h] is the widget's size. */
/** [dark]: null = the phone's current mode. */
class WidgetRenderer(
    private val ctx: Context, private val w: Float, private val h: Float, private val data: JSONObject?, dark: Boolean?,
) {
    private val p = when (dark) {
        null -> Palette.of(ctx)
        true -> Palette.DARK
        false -> Palette.LIGHT
    }
    private val mono = Fonts.get(ctx, "IBMPlexMono-Regular", Typeface.MONOSPACE)
    private val monoMedium = Fonts.get(ctx, "IBMPlexMono-Medium", Typeface.MONOSPACE)
    private val sans = Fonts.get(ctx, "IBMPlexSans-Regular", Typeface.SANS_SERIF)
    private val labels = data?.optJSONObject("labels")
    private val cur = data?.optString("cur") ?: ""
    private val fresh = data?.optString("date") == SimpleDateFormat("yyyy-MM-dd", Locale.US).format(Date())

    private lateinit var bitmap: Bitmap
    private lateinit var c: Canvas

    private fun begin() {
        val density = ctx.resources.displayMetrics.density
        // Two bitmaps per widget (light + dark) must stay well under the RemoteViews memory limit.
        val scale = min(density, sqrt(900_000f / (w * h)))
        bitmap = Bitmap.createBitmap(max(1, (w * scale).roundToInt()), max(1, (h * scale).roundToInt()), Bitmap.Config.ARGB_8888)
        c = Canvas(bitmap)
        c.scale(scale, scale)
        val fill = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = p.bg }
        val r = min(18f, h / 2)
        c.drawRoundRect(RectF(0f, 0f, w, h), r, r, fill)
        val stroke = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = p.rule; style = Paint.Style.STROKE; strokeWidth = 1f }
        c.drawRoundRect(RectF(0.5f, 0.5f, w - 0.5f, h - 0.5f), r, r, stroke)
    }

    private fun label(key: String, fallback: Int): String = labels?.optString(key)?.takeIf { it.isNotEmpty() } ?: ctx.getString(fallback)

    private fun paint(size: Float, tf: Typeface, color: Int, align: Paint.Align = Paint.Align.LEFT, spacing: Float = 0f) =
        Paint(Paint.ANTI_ALIAS_FLAG).apply {
            textSize = size
            typeface = tf
            this.color = color
            textAlign = align
            letterSpacing = spacing
        }

    /** Draws [s] shrunk to fit [maxWidth]; returns the width used. */
    private fun text(s: String, x: Float, y: Float, size: Float, tf: Typeface, color: Int,
                     align: Paint.Align = Paint.Align.LEFT, spacing: Float = 0f, maxWidth: Float = Float.MAX_VALUE): Float {
        val pt = paint(size, tf, color, align, spacing)
        val width = pt.measureText(s)
        if (width > maxWidth && width > 0) pt.textSize = size * maxWidth / width
        c.drawText(s, x, y, pt)
        return min(width, maxWidth)
    }

    private fun rect(l: Float, t: Float, r: Float, b: Float, color: Int) {
        c.drawRect(l, t, r, b, Paint().apply { this.color = color })
    }

    private fun caption(s: String, x: Float, y: Float, maxWidth: Float = w - 28f) =
        text(s.uppercase(), x, y, 9.5f, mono, p.muted, spacing = 0.1f, maxWidth = maxWidth)

    /** A centered hint when there is nothing (fresh) to show. */
    private fun hint(top: Float, msg: String) {
        text(msg, 14f, top, 12f, sans, p.muted, maxWidth = w - 28f)
    }

    private fun done(): Bitmap = bitmap

    // --- 3 · "Left today" (2×1) ---
    fun today(): Bitmap {
        begin()
        val t = data?.optJSONObject("today")
        val over = t?.optBoolean("over") == true
        caption(if (over) label("over", R.string.widget_over) else label("today", R.string.widget_today_name), 14f, 21f)
        when {
            data == null || !fresh -> hint(h / 2 + 8f, label("open", R.string.widget_open_app))
            !data.optBoolean("budgetOn") || t == null -> hint(h / 2 + 8f, label("budgetOff", R.string.widget_budget_off))
            else -> {
                val base = h - 25f
                val big = min(27f, h * 0.34f)
                val of = "${label("of", R.string.widget_of)} ${t.optString("allowance")}"
                val ofWidth = text(of, w - 14f, base, 10f, mono, p.muted, Paint.Align.RIGHT)
                text(cur + t.optString("left"), 14f, base, big, monoMedium, if (over) p.bad else p.accent, maxWidth = w - 36f - ofWidth)
                rect(14f, h - 16f, w - 14f, h - 12f, p.track)
                val share = t.optDouble("spentShare", 0.0).coerceIn(0.0, 1.0).toFloat()
                rect(14f, h - 16f, 14f + (w - 28f) * share, h - 12f, if (over) p.bad else p.ink)
            }
        }
        return done()
    }

    // --- 4 · "Lasts until" (2×1) ---
    fun runway(): Bitmap {
        begin()
        val r = data?.optJSONObject("runway")
        val sparkW = if (w >= 150f) 60f else 0f
        val textW = w - 28f - (if (sparkW > 0) sparkW + 8f else 0f)
        caption(label("runway", R.string.widget_runway_name), 14f, 21f, textW)
        if (r == null) {
            hint(h / 2 + 8f, label("open", R.string.widget_open_app))
            return done()
        }
        text(r.optString("date"), 14f, min(h - 22f, h * 0.5f + 10f), min(25f, h * 0.32f), monoMedium, p.accent, maxWidth = textW)
        text(r.optString("sub"), 14f, h - 12f, 10f, sans, p.muted, maxWidth = textW)
        val pts = r.optJSONArray("points")
        if (sparkW > 0 && pts != null && pts.length() > 1) {
            val left = w - 12f - sparkW
            val right = w - 12f - 4f
            val top = 14f
            val bottom = h - 15f
            val n = pts.length()
            val path = Path().apply { moveTo(left, bottom) }
            for (i in 0 until n) {
                val x0 = left + (right - left) * i / n
                val x1 = left + (right - left) * (i + 1) / n
                val y = bottom - (bottom - top) * pts.optDouble(i, 0.0).coerceIn(0.0, 1.0).toFloat()
                path.lineTo(x0, y)
                path.lineTo(x1, y)
            }
            path.lineTo(right, bottom)
            path.close()
            c.drawPath(path, Paint(Paint.ANTI_ALIAS_FLAG).apply { color = p.area })
            rect(left, bottom, w - 12f, bottom + 1.5f, p.ink)
            val lastY = bottom - (bottom - top) * pts.optDouble(n - 1, 0.0).coerceIn(0.0, 1.0).toFloat()
            rect(right - 3f, lastY - 3.5f, right + 4f, lastY + 3.5f, Palette.YELLOW)
        }
        return done()
    }

    // --- 2 · Summary (2×2) ---
    fun summary(): Bitmap {
        begin()
        val m = data?.optJSONObject("month")
        caption("${m?.optString("name") ?: ""} · ${label("spent", R.string.widget_spent)}", 14f, 21.5f)
        if (m == null) {
            hint(h / 2, label("open", R.string.widget_open_app))
            return done()
        }
        val spentW = text(m.optString("spent"), 14f, 50f, 21f, monoMedium, p.ink, maxWidth = w - 70f)
        if (data!!.optBoolean("budgetOn")) {
            text("/ ${m.optString("budget")}", 14f + spentW + 4f, 50f, 10.5f, mono, p.muted, maxWidth = w - 32f - spentW)
            rect(14f, 59f, w - 14f, 65f, p.track)
            rect(14f, 59f, 14f + (w - 28f) * m.optDouble("spentShare", 0.0).coerceIn(0.0, 1.0).toFloat(), 65f, p.accent)
            val tick = 14f + (w - 28f) * m.optDouble("elapsed", 0.0).coerceIn(0.0, 1.0).toFloat()
            rect(tick - 1f, 56f, tick + 1f, 68f, p.ink)
        }
        val rows = mutableListOf<Triple<String, String, Int>>()
        if (data.optBoolean("budgetOn")) {
            rows += Triple(label("left", R.string.widget_left).replaceFirstChar { it.uppercase() }, m.optString("left"), p.ink)
            rows += Triple(label("perDay", R.string.widget_per_day), m.optString("perDay"), p.ink)
            rows += Triple(label("pace", R.string.widget_pace), m.optString("pace"), if (m.optBoolean("paceGood")) p.good else p.bad)
        } else {
            rows += Triple(label("income", R.string.widget_income), m.optString("income"), p.good)
        }
        val top = 78f
        val rowH = min(28f, (h - top - 12f) / rows.size)
        rows.forEachIndexed { i, (name, value, color) ->
            val y = top + i * rowH
            rect(14f, y, w - 14f, y + 1f, p.rule)
            text(name, 14f, y + rowH / 2 + 4.5f, 11f, sans, p.muted, maxWidth = w / 2)
            text(value, w - 14f, y + rowH / 2 + 4.5f, 12f, monoMedium, color, Paint.Align.RIGHT)
        }
        rect(14f, top + rows.size * rowH, w - 14f, top + rows.size * rowH + 1f, p.rule)
        return done()
    }

    // --- 1 · Month calendar (4×2) ---
    fun calendar(): Bitmap {
        begin()
        val m = data?.optJSONObject("month")
        if (m == null) {
            caption(label("byDays", R.string.widget_calendar_name), 14f, 21f)
            hint(h / 2, label("open", R.string.widget_open_app))
            return done()
        }
        if (data!!.optBoolean("budgetOn")) {
            val valueW = text(cur + m.optString("left"), w - 14f, 21f, 13f, monoMedium, p.accent, Paint.Align.RIGHT)
            text(label("leftLower", R.string.widget_left) + " ", w - 14f - valueW, 21f, 11f, sans, p.muted, Paint.Align.RIGHT)
        }
        caption("${m.optString("name")} · ${label("byDays", R.string.widget_calendar_name)}", 14f, 21f, w * 0.55f)
        val days = m.optJSONArray("days")
        val n = days?.length() ?: 0
        val lead = m.optInt("lead")
        val today = m.optInt("today")
        val rows = max(1, ceil((lead + n) / 7.0).toInt())
        val left = 14f
        val top = 30f
        val gw = w - 28f
        val gh = h - top - 12f
        rect(left, top, left + gw, top + gh, p.rule)
        val cw = (gw - 8f) / 7f
        val ch = (gh - (rows + 1)) / rows
        val accentSoft = (p.accent and 0x00FFFFFF) or (0x40 shl 24)
        val ring = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = p.accent; style = Paint.Style.STROKE; strokeWidth = 1.5f }
        for (i in 0 until rows * 7) {
            val col = i % 7
            val row = i / 7
            val x = left + 1f + col * (cw + 1f)
            val y = top + 1f + row * (ch + 1f)
            val day = i - lead + 1
            if (day < 1 || day > n) {
                rect(x, y, x + cw, y + ch, p.shade)
                continue
            }
            val code = days!!.optInt(day - 1)
            val color = when {
                day == today && fresh -> p.bg
                code == 1 -> p.within
                code == 2 -> p.over
                code == 3 -> accentSoft
                else -> p.bg
            }
            rect(x, y, x + cw, y + ch, color)
            if (day == today && fresh) c.drawRect(x + 0.75f, y + 0.75f, x + cw - 0.75f, y + ch - 0.75f, ring)
            if (ch >= 12f) text("$day", x + 3f, y + 9.5f, 8.5f, mono, p.muted)
        }
        return done()
    }

    // --- 5 · Quick add (4×1); zones match layout/widget_quick.xml ---
    fun quick(): Bitmap {
        begin()
        val btn = RectF(12f, 12f, 84f, h - 12f)
        c.drawRoundRect(btn, 6f, 6f, Paint(Paint.ANTI_ALIAS_FLAG).apply { color = p.btnBg })
        val cx = btn.centerX()
        val withText = btn.height() >= 44f
        val cy = if (withText) btn.centerY() - 7f else btn.centerY()
        val plus = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = p.btnFg; strokeWidth = 2.4f; strokeCap = Paint.Cap.ROUND }
        c.drawLine(cx - 7f, cy, cx + 7f, cy, plus)
        c.drawLine(cx, cy - 7f, cx, cy + 7f, plus)
        if (withText) text(label("record", R.string.widget_record), cx, btn.centerY() + 15f, 10f, mono, p.btnFg, Paint.Align.CENTER, maxWidth = 64f)

        val grid = RectF(92f, 12f, w - 12f, h - 12f)
        val clip = Path().apply { addRoundRect(grid, 6f, 6f, Path.Direction.CW) }
        c.save()
        c.clipPath(clip)
        rect(grid.left, grid.top, grid.right, grid.bottom, p.rule)
        val cats = data?.optJSONArray("quick")
        val cellW = (grid.width() - 5f) / 4f
        for (i in 0 until 4) {
            val x = grid.left + 1f + i * (cellW + 1f)
            rect(x, grid.top + 1f, x + cellW, grid.bottom - 1f, p.bg)
            val cat = cats?.optJSONObject(i) ?: continue
            val mid = x + cellW / 2
            val ccy = grid.centerY()
            rect(mid - 5f, ccy - 15f, mid + 5f, ccy - 5f, cat.optInt("color"))
            text(cat.optString("name"), mid, ccy + 12f, 11f, sans, p.ink, Paint.Align.CENTER, maxWidth = cellW - 6f)
        }
        c.restore()
        return done()
    }

    fun description(kind: WidgetKind): String {
        val t = data?.optJSONObject("today")
        val m = data?.optJSONObject("month")
        val r = data?.optJSONObject("runway")
        return when (kind) {
            WidgetKind.TODAY -> "${label("today", R.string.widget_today_name)}: ${t?.let { cur + it.optString("left") } ?: "—"}"
            WidgetKind.RUNWAY -> "${label("runway", R.string.widget_runway_name)}: ${r?.optString("date") ?: "—"}"
            WidgetKind.SUMMARY -> "${label("spent", R.string.widget_spent)}: ${m?.optString("spent") ?: "—"}"
            WidgetKind.CALENDAR -> "${label("byDays", R.string.widget_calendar_name)}: ${label("leftLower", R.string.widget_left)} ${m?.optString("left") ?: "—"}"
            WidgetKind.QUICK -> label("record", R.string.widget_record)
        }
    }
}
