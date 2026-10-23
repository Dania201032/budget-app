package app.budget.budget_app.widgets

import android.content.Context
import android.content.res.Configuration
import android.graphics.Bitmap
import android.util.Log
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * Developer tool: draws the five widgets with the same renderer on demo figures (the ones of the
 * design mock-ups, never the user's data), per language and light/dark, into
 * Android/data/<package>/files/previews. Those PNGs become the widget-picker previews
 * (res/drawable-*-nodpi/widget_preview_*). Run with:
 *   adb shell am broadcast -a app.budget.widget.RENDER_PREVIEWS -n app.budget.budget_app/.widgets.WidgetPreviewReceiver   (debug builds only)
 */
object WidgetPreviews {
    private const val TAG = "BudgetWidgets"

    private data class Lang(
        val code: String, val month: String, val sub: String, val cats: List<String>,
    )

    private val langs = listOf(
        Lang("en", "OCTOBER", "≈ 1 mo 25 d", listOf("Food", "Drinks", "Transport", "Shopping")),
        Lang("ru", "ОКТЯБРЬ", "≈ 1 мес. 25 дн.", listOf("Еда", "Питьё", "Транспорт", "Покупки")),
        Lang("zh", "十月", "约 1 个月 25 天", listOf("餐饮", "饮品", "交通", "购物")),
        Lang("kk", "ҚАЗАН", "≈ 1 ай 25 күн", listOf("Тамақ", "Сусындар", "Көлік", "Сатып алулар")),
        Lang("de", "OKTOBER", "≈ 1 Mon. 25 T.", listOf("Essen", "Getränke", "Verkehr", "Einkäufe")),
        Lang("nl", "OKTOBER", "≈ 1 mnd 25 d", listOf("Eten", "Drinken", "Vervoer", "Winkelen")),
    )

    private fun demo(lang: Lang): JSONObject {
        val spend = intArrayOf(96, 142, 188, 110, 74, 160, 131, 205, 88, 117, 152, 169, 150, 38)
        val days = JSONArray().apply {
            for (d in 1..31) put(if (d > spend.size) 0 else if (spend[d - 1] > 145) 2 else 1)
        }
        val colors = listOf(0xFF2F7A66, 0xFF8C6A4A, 0xFF4A6FA5, 0xFFC98A1E)
        return JSONObject()
            .put("date", SimpleDateFormat("yyyy-MM-dd", Locale.US).format(Date()))
            .put("cur", "¥")
            .put("budgetOn", true)
            .put("today", JSONObject().put("left", "111").put("allowance", "149").put("over", false).put("spentShare", 0.255))
            .put(
                "month", JSONObject()
                    .put("name", lang.month).put("spent", "1 820").put("budget", "4 500").put("left", "2 680")
                    .put("perDay", "158").put("pace", "+212").put("paceGood", true).put("income", "3 000")
                    .put("spentShare", 0.404).put("elapsed", 0.452).put("lead", 3).put("today", 14).put("days", days),
            )
            .put(
                "runway", JSONObject().put("date", "09.12").put("sub", lang.sub)
                    .put("points", JSONArray(listOf(1.0, 0.93, 0.86, 0.78, 0.71, 0.63, 0.55, 0.47, 0.38, 0.29, 0.2, 0.1))),
            )
            .put(
                "quick", JSONArray().apply {
                    lang.cats.forEachIndexed { i, name -> put(JSONObject().put("id", i + 1).put("name", name).put("color", colors[i].toInt())) }
                },
            )
    }

    fun renderAll(ctx: Context) {
        val dir = File(ctx.getExternalFilesDir(null), "previews").apply { mkdirs() }
        for (lang in langs) {
            // Labels come from the widget string resources of that language.
            val config = Configuration(ctx.resources.configuration).apply { setLocale(Locale(lang.code)) }
            val lctx = ctx.createConfigurationContext(config)
            val data = demo(lang)
            for (kind in WidgetKind.values()) {
                for (dark in listOf(false, true)) {
                    val r = WidgetRenderer(lctx, kind.defW, kind.defH, data, dark)
                    val bmp = when (kind) {
                        WidgetKind.CALENDAR -> r.calendar()
                        WidgetKind.SUMMARY -> r.summary()
                        WidgetKind.TODAY -> r.today()
                        WidgetKind.RUNWAY -> r.runway()
                        WidgetKind.QUICK -> r.quick()
                    }
                    val name = "widget_preview_${kind.name.lowercase()}_${lang.code}_${if (dark) "dark" else "light"}.png"
                    File(dir, name).outputStream().use { bmp.compress(Bitmap.CompressFormat.PNG, 100, it) }
                }
            }
        }
        Log.i(TAG, "previews written to $dir")
    }
}
