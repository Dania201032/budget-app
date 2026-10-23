package app.budget.budget_app.widgets

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.util.Log
import app.budget.budget_app.NativeStrings
import app.budget.budget_app.capture.CaptureInbox
import app.budget.budget_app.capture.PaymentAccessibilityService
import app.budget.budget_app.capture.PaymentNotificationListener
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel
import java.util.Calendar
import java.util.concurrent.Executors

/**
 * Keeps the widgets current without opening the app: after a payment is captured in the
 * background, at midnight and when the clock changes, the app's own Dart code recomputes and
 * pushes a fresh snapshot — through the running app if it is alive, else a headless engine.
 */
object WidgetRefresh {
    const val ACTION_MIDNIGHT = "app.budget.widget.MIDNIGHT"
    const val ACTION_RENDER_PREVIEWS = "app.budget.widget.RENDER_PREVIEWS"
    private const val TAG = "BudgetWidgets"
    private const val DEBOUNCE_MS = 1500L
    private const val ENGINE_TIMEOUT_MS = 45_000L

    private val main = Handler(Looper.getMainLooper())
    private val io = Executors.newSingleThreadExecutor()
    private var scheduled = false
    private var engine: FlutterEngine? = null
    private val waiting = mutableListOf<() -> Unit>()

    /** The running app's widgets channel; set by MainActivity while its engine lives. */
    @Volatile
    var appChannel: MethodChannel? = null

    /** A payment was written to the inbox in the background: recompute only if widgets are placed. */
    fun afterCapture(ctx: Context) {
        if (HomeWidgets.hasWidgets(ctx)) request(ctx)
    }

    /** Ask for a refresh; bursts (several captures in a row) are coalesced. [done] runs when it finished. */
    fun request(ctx: Context, done: (() -> Unit)? = null) {
        val app = ctx.applicationContext
        main.post {
            if (done != null) waiting += done
            if (scheduled) return@post
            scheduled = true
            main.postDelayed({
                scheduled = false
                run(app)
            }, DEBOUNCE_MS)
        }
    }

    private fun finished() {
        val callbacks = waiting.toList()
        waiting.clear()
        callbacks.forEach { runCatching { it() } }
    }

    private fun run(ctx: Context) {
        Log.i(TAG, if (appChannel != null) "refresh through the running app" else "refresh in a headless engine")
        appChannel?.let { channel ->
            channel.invokeMethod("refresh", null, object : MethodChannel.Result {
                override fun success(result: Any?) = finished()
                override fun error(code: String, message: String?, details: Any?) = finished()
                override fun notImplemented() = finished()
            })
            return
        }
        if (engine != null) return // already running; it reads the newest data anyway
        try {
            val loader = FlutterInjector.instance().flutterLoader()
            loader.startInitialization(ctx)
            loader.ensureInitializationComplete(ctx, null)
            val e = FlutterEngine(ctx)
            engine = e
            val messenger = e.dartExecutor.binaryMessenger
            MethodChannel(messenger, "budget/widgets").setMethodCallHandler { call, result ->
                when (call.method) {
                    "update" -> {
                        val json = call.argument<String>("json") ?: "{}"
                        io.execute {
                            runCatching { HomeWidgets.update(ctx, json) }
                            main.post { result.success(null) }
                        }
                    }
                    "backgroundDone" -> {
                        result.success(null)
                        main.post { stopEngine() }
                    }
                    else -> result.notImplemented()
                }
            }
            // The few capture calls the app makes on start.
            MethodChannel(messenger, "budget/capture").setMethodCallHandler { call, result ->
                when (call.method) {
                    "consumeInbox" -> result.success(CaptureInbox.consume(ctx))
                    "status" -> result.success(
                        mapOf(
                            "accessibility" to isEnabled(ctx, "enabled_accessibility_services", PaymentAccessibilityService::class.java),
                            "notifications" to isEnabled(ctx, "enabled_notification_listeners", PaymentNotificationListener::class.java),
                            "postNotifications" to CaptureInbox.canNotify(ctx),
                        )
                    )
                    "setLanguage" -> {
                        NativeStrings.setLang(ctx, call.argument<String>("lang") ?: "ru")
                        result.success(null)
                    }
                    "takePendingAction" -> result.success(null)
                    else -> result.notImplemented()
                }
            }
            e.dartExecutor.executeDartEntrypoint(DartExecutor.DartEntrypoint(loader.findAppBundlePath(), "widgetsBackground"))
            main.postDelayed({ if (engine === e) stopEngine() }, ENGINE_TIMEOUT_MS)
        } catch (t: Throwable) {
            stopEngine()
        }
    }

    private fun stopEngine() {
        engine?.let {
            runCatching { it.destroy() }
            Log.i(TAG, "headless engine stopped")
        }
        engine = null
        finished()
    }

    private fun isEnabled(ctx: Context, key: String, cls: Class<*>): Boolean {
        val enabled = Settings.Secure.getString(ctx.contentResolver, key) ?: return false
        val component = ComponentName(ctx, cls)
        return enabled.split(':').any { ComponentName.unflattenFromString(it) == component }
    }

    /** Wakes the refresh shortly after the next midnight (inexact: no special permission needed). */
    fun scheduleMidnight(ctx: Context) {
        val am = ctx.getSystemService(AlarmManager::class.java) ?: return
        val next = Calendar.getInstance().apply {
            add(Calendar.DAY_OF_YEAR, 1)
            set(Calendar.HOUR_OF_DAY, 0)
            set(Calendar.MINUTE, 1)
            set(Calendar.SECOND, 0)
            set(Calendar.MILLISECOND, 0)
        }
        val pi = PendingIntent.getBroadcast(
            ctx, 7301, Intent(ctx, WidgetRefreshReceiver::class.java).setAction(ACTION_MIDNIGHT),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        am.setAndAllowWhileIdle(AlarmManager.RTC, next.timeInMillis, pi)
    }
}

/** Midnight alarm (our own PendingIntent) and clock / time zone changes (from the system). Not exported. */
class WidgetRefreshReceiver : BroadcastReceiver() {
    private val handled = setOf(Intent.ACTION_TIME_CHANGED, Intent.ACTION_TIMEZONE_CHANGED, WidgetRefresh.ACTION_MIDNIGHT)

    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action !in handled) return
        if (!HomeWidgets.hasWidgets(context)) return
        val pending = goAsync()
        WidgetRefresh.scheduleMidnight(context)
        WidgetRefresh.request(context) { runCatching { pending.finish() } }
    }
}

/**
 * Renders the widget pickers' preview images (res/drawable-*-nodpi) on a broadcast from adb. Declared
 * only in the debug manifest (src/debug/AndroidManifest.xml): release builds can't be asked to do it.
 */
class WidgetPreviewReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action == WidgetRefresh.ACTION_RENDER_PREVIEWS) WidgetPreviews.renderAll(context)
    }
}
