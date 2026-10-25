package app.budget.budget_app

import android.app.AlarmManager
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import app.budget.budget_app.capture.CaptureInbox
import org.json.JSONArray

/**
 * Reminders of regular payments and incomes ("Rent 3 000 ¥ today") and the evening "nothing
 * recorded today" one. The app sends the due times of the next weeks ([set]); one inexact alarm at
 * a time wakes [ReminderReceiver], which shows what is due and arms the next one. Rebuilt after a
 * reboot. An evening reminder (`idle`) is dropped when a payment was caught that day meanwhile.
 */
object Reminders {
    private const val PREFS = "budget_reminders"
    private const val KEY_LIST = "list"
    private const val KEY_SHOWN = "shown_until"
    private const val KEY_ACTIVE = "active_at"
    private const val CHANNEL = "reminders"

    fun set(ctx: Context, json: String) {
        prefs(ctx).edit().putString(KEY_LIST, json).apply()
        schedule(ctx)
    }

    private fun prefs(ctx: Context) = ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    private data class Item(val ts: Long, val title: String, val text: String, val idle: Boolean)

    /** A payment was caught now (the app was not necessarily open). */
    fun noteActivity(ctx: Context) {
        prefs(ctx).edit().putLong(KEY_ACTIVE, System.currentTimeMillis()).apply()
    }

    private fun sameDay(a: Long, b: Long): Boolean {
        val ca = java.util.Calendar.getInstance().apply { timeInMillis = a }
        val cb = java.util.Calendar.getInstance().apply { timeInMillis = b }
        return ca.get(java.util.Calendar.YEAR) == cb.get(java.util.Calendar.YEAR) &&
            ca.get(java.util.Calendar.DAY_OF_YEAR) == cb.get(java.util.Calendar.DAY_OF_YEAR)
    }

    private fun items(ctx: Context): List<Item> = runCatching {
        val a = JSONArray(prefs(ctx).getString(KEY_LIST, "[]"))
        (0 until a.length()).map { i ->
            val o = a.getJSONObject(i)
            Item(o.getLong("ts"), o.optString("title"), o.optString("text"), o.optBoolean("idle"))
        }
    }.getOrDefault(emptyList())

    private fun pending(ctx: Context): PendingIntent = PendingIntent.getBroadcast(
        ctx, 7401, Intent(ctx, ReminderReceiver::class.java).setAction("app.budget.REMINDER"),
        PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
    )

    fun schedule(ctx: Context) {
        val shown = prefs(ctx).getLong(KEY_SHOWN, 0)
        val next = items(ctx).map { it.ts }.filter { it > shown }.minOrNull()
        val am = ctx.getSystemService(AlarmManager::class.java)
        if (next == null) {
            am.cancel(pending(ctx))
            return
        }
        am.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, maxOf(next, System.currentTimeMillis() + 1000), pending(ctx))
    }

    /** Shows everything due by now that was not shown yet, then arms the next alarm. */
    fun fire(ctx: Context) {
        val now = System.currentTimeMillis()
        val shown = prefs(ctx).getLong(KEY_SHOWN, 0)
        val active = prefs(ctx).getLong(KEY_ACTIVE, 0)
        val dueAll = items(ctx).filter { it.ts in (shown + 1)..(now + 60_000) }
        val due = dueAll.filter { !it.idle || !sameDay(active, it.ts) }
        if (due.isNotEmpty() && CaptureInbox.canNotify(ctx)) {
            val nm = ctx.getSystemService(NotificationManager::class.java)
            if (nm.getNotificationChannel(CHANNEL) == null) {
                nm.createNotificationChannel(
                    NotificationChannel(CHANNEL, NativeStrings.t(ctx, "reminders_channel"), NotificationManager.IMPORTANCE_DEFAULT),
                )
            }
            val open = PendingIntent.getActivity(
                ctx, 7402, Intent(ctx, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
                PendingIntent.FLAG_IMMUTABLE,
            )
            for (item in due) {
                nm.notify(
                    (item.ts / 1000 % 100000).toInt() + 20000,
                    Notification.Builder(ctx, CHANNEL)
                        .setSmallIcon(R.drawable.ic_stat_payment)
                        .setContentTitle(item.title)
                        .setContentText(item.text)
                        .setContentIntent(open)
                        .setAutoCancel(true)
                        .build(),
                )
            }
        }
        if (dueAll.isNotEmpty()) prefs(ctx).edit().putLong(KEY_SHOWN, dueAll.maxOf { it.ts }).apply()
        schedule(ctx)
    }
}

/** The reminder alarm and the reboot (alarms don't survive it). Not exported. */
class ReminderReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        when (intent.action) {
            Intent.ACTION_BOOT_COMPLETED -> Reminders.schedule(context)
            "app.budget.REMINDER" -> Reminders.fire(context)
        }
    }
}
