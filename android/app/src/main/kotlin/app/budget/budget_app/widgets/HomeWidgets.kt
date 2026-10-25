package app.budget.budget_app.widgets

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.graphics.drawable.Icon
import android.os.Build
import android.os.Bundle
import android.util.Log
import android.view.View
import android.widget.RemoteViews
import app.budget.budget_app.MainActivity
import app.budget.budget_app.R
import org.json.JSONObject
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/** The five home-screen widgets. Sizes are the design sizes in dp, used until the launcher reports real ones. */
enum class WidgetKind(val defW: Float, val defH: Float, val route: String) {
    CALENDAR(358f, 184f, "overview_calendar"),
    SUMMARY(171f, 184f, "home"),
    TODAY(171f, 84f, "add"),
    RUNWAY(171f, 84f, "analytics"),
    QUICK(358f, 84f, "add"),
}

abstract class LedgerWidget : AppWidgetProvider() {
    abstract val kind: WidgetKind

    override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray) {
        ids.forEach { HomeWidgets.render(context, manager, it, kind) }
        // Every 30 min (and after boot): a snapshot from yesterday gets recomputed by the app's code.
        WidgetRefresh.scheduleMidnight(context)
        if (!HomeWidgets.isFresh(context)) WidgetRefresh.request(context)
    }

    override fun onEnabled(context: Context) {
        WidgetRefresh.request(context)
    }

    override fun onAppWidgetOptionsChanged(context: Context, manager: AppWidgetManager, id: Int, options: Bundle) {
        HomeWidgets.render(context, manager, id, kind)
    }
}

class CalendarWidget : LedgerWidget() { override val kind = WidgetKind.CALENDAR }
class SummaryWidget : LedgerWidget() { override val kind = WidgetKind.SUMMARY }
class TodayWidget : LedgerWidget() { override val kind = WidgetKind.TODAY }
class RunwayWidget : LedgerWidget() { override val kind = WidgetKind.RUNWAY }
class QuickWidget : LedgerWidget() { override val kind = WidgetKind.QUICK }

/** Figures prepared by the Flutter side (formatted, localized), kept until the next update. */
object WidgetSnapshot {
    private const val PREFS = "home_widgets"
    private const val KEY = "snapshot"

    fun save(ctx: Context, json: String) {
        ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().putString(KEY, json).apply()
    }

    fun load(ctx: Context): JSONObject? =
        ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getString(KEY, null)
            ?.let { runCatching { JSONObject(it) }.getOrNull() }
}

object HomeWidgets {
    private const val EXTRA_ROUTE = "app.budget.widget.ROUTE"
    private const val EXTRA_CATEGORY = "app.budget.widget.CATEGORY"

    private val providers = listOf(
        CalendarWidget::class.java to WidgetKind.CALENDAR,
        SummaryWidget::class.java to WidgetKind.SUMMARY,
        TodayWidget::class.java to WidgetKind.TODAY,
        RunwayWidget::class.java to WidgetKind.RUNWAY,
        QuickWidget::class.java to WidgetKind.QUICK,
    )

    /** Called by the app whenever its numbers change. */
    fun update(ctx: Context, json: String) {
        WidgetSnapshot.save(ctx, json)
        if (hasWidgets(ctx)) WidgetRefresh.scheduleMidnight(ctx)
        val manager = AppWidgetManager.getInstance(ctx)
        var count = 0
        for ((cls, kind) in providers) {
            manager.getAppWidgetIds(ComponentName(ctx, cls)).forEach {
                render(ctx, manager, it, kind)
                count++
            }
        }
        Log.i("BudgetWidgets", "snapshot updated, $count widget(s) redrawn")
    }

    /** Asks the launcher to place [kind] on the home screen (it shows its own confirmation). */
    fun pin(ctx: Context, kind: WidgetKind): Boolean {
        val manager = AppWidgetManager.getInstance(ctx)
        if (Build.VERSION.SDK_INT < 26 || !manager.isRequestPinAppWidgetSupported) return false
        val cls = providers.first { it.second == kind }.first
        return manager.requestPinAppWidget(ComponentName(ctx, cls), null, null)
    }

    fun hasWidgets(ctx: Context): Boolean {
        val manager = AppWidgetManager.getInstance(ctx)
        return providers.any { (cls, _) -> manager.getAppWidgetIds(ComponentName(ctx, cls)).isNotEmpty() }
    }

    /** The stored snapshot was made today. */
    fun isFresh(ctx: Context): Boolean =
        WidgetSnapshot.load(ctx)?.optString("date") == SimpleDateFormat("yyyy-MM-dd", Locale.US).format(Date())

    fun render(ctx: Context, manager: AppWidgetManager, id: Int, kind: WidgetKind) {
        val options = manager.getAppWidgetOptions(id)
        // Portrait size: min width × max height.
        val w = options.getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_WIDTH).takeIf { it > 0 }?.toFloat() ?: kind.defW
        val h = options.getInt(AppWidgetManager.OPTION_APPWIDGET_MAX_HEIGHT).takeIf { it > 0 }?.toFloat() ?: kind.defH
        val data = WidgetSnapshot.load(ctx)
        fun draw(dark: Boolean?): android.graphics.Bitmap {
            val r = WidgetRenderer(ctx, w, h, data, dark)
            return when (kind) {
                WidgetKind.CALENDAR -> r.calendar()
                WidgetKind.SUMMARY -> r.summary()
                WidgetKind.TODAY -> r.today()
                WidgetKind.RUNWAY -> r.runway()
                WidgetKind.QUICK -> r.quick()
            }
        }
        val renderer = WidgetRenderer(ctx, w, h, data, null)
        val views = RemoteViews(ctx.packageName, if (kind == WidgetKind.QUICK) R.layout.widget_quick else R.layout.widget_image)
        if (Build.VERSION.SDK_INT >= 31) {
            // Both looks at once: the launcher switches them when the phone's theme changes.
            views.setIcon(R.id.widget_image, "setImageIcon", Icon.createWithBitmap(draw(false)), Icon.createWithBitmap(draw(true)))
        } else {
            views.setImageViewBitmap(R.id.widget_image, draw(null))
        }
        views.setContentDescription(R.id.widget_image, renderer.description(kind))
        if (kind == WidgetKind.QUICK) {
            views.setOnClickPendingIntent(R.id.quick_add, open(ctx, id, 0, "add", null))
            val cats = data?.optJSONArray("quick")
            val zones = listOf(R.id.quick_c0, R.id.quick_c1, R.id.quick_c2, R.id.quick_c3)
            zones.forEachIndexed { i, zone ->
                val cat = cats?.optJSONObject(i)
                if (cat == null) {
                    views.setViewVisibility(zone, View.INVISIBLE)
                } else {
                    views.setViewVisibility(zone, View.VISIBLE)
                    views.setContentDescription(zone, cat.optString("name"))
                    views.setOnClickPendingIntent(zone, open(ctx, id, i + 1, "add", cat.optLong("id")))
                }
            }
        } else {
            views.setOnClickPendingIntent(R.id.widget_image, open(ctx, id, 0, kind.route, null))
        }
        manager.updateAppWidget(id, views)
    }

    /** Opens the app at [route] ("add", "analytics"…): widgets and the Quick Settings tile. */
    fun routeIntent(ctx: Context, route: String): Intent = Intent(ctx, MainActivity::class.java)
        .setAction("app.budget.widget.OPEN")
        .putExtra(EXTRA_ROUTE, route)
        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)

    private fun open(ctx: Context, widgetId: Int, zone: Int, route: String, categoryId: Long?): PendingIntent {
        val intent = routeIntent(ctx, route)
        if (categoryId != null) intent.putExtra(EXTRA_CATEGORY, categoryId)
        // The request code keeps every widget zone's intent distinct.
        return PendingIntent.getActivity(
            ctx, widgetId * 10 + zone, intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    /** A tap on a widget, as a pending action for the Dart side. */
    fun actionFrom(intent: Intent?): Map<String, Any>? {
        val route = intent?.getStringExtra(EXTRA_ROUTE) ?: return null
        val category = intent.getLongExtra(EXTRA_CATEGORY, 0)
        intent.removeExtra(EXTRA_ROUTE)
        intent.removeExtra(EXTRA_CATEGORY)
        return mapOf("type" to "widget", "route" to route, "categoryId" to category)
    }
}
