package app.budget.budget_app.capture

import android.Manifest
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import app.budget.budget_app.MainActivity
import app.budget.budget_app.NativeStrings
import app.budget.budget_app.R
import app.budget.budget_app.widgets.WidgetRefresh
import java.io.File
import java.math.BigDecimal

/**
 * Hand-off point between the capture services and the Flutter app.
 * Captured payments are appended to a JSONL file; the Flutter side consumes it, merges
 * screen + notification duplicates and turns them into transactions.
 * Also shows a "recorded" notification, updating it when the second source of the same payment arrives.
 */
object CaptureInbox {
    private const val FILE_NAME = "capture_inbox.jsonl"
    const val CHANNEL_ID = "captured_payments"
    private const val SAME_PAYMENT_WINDOW_MS = 3 * 60_000L

    /** Alipay shows the success card again when its home page is reopened later. */
    private const val SAME_SCREEN_WINDOW_MS = 30 * 60_000L

    private data class Recent(val payment: CapturedPayment, val notificationId: Int)

    private val recent = ArrayDeque<Recent>()
    private var nextNotificationId = 1000

    /**
     * Last cashier (confirmation) screen, set by the accessibility service. Transfers have no
     * readable success screen, only a notification without the recipient — the cashier has it.
     */
    @Volatile
    var lastCashier: PaymentParsers.CashierInfo? = null

    @Synchronized
    fun record(ctx: Context, captured: CapturedPayment) {
        var p = captured
        val cashier = lastCashier
        if (p.merchant == null && cashier != null && cashier.amountMinor == p.amountMinor &&
            p.ts - cashier.ts in -10_000L..SAME_PAYMENT_WINDOW_MS
        ) {
            p = p.copy(merchant = cashier.merchant)
        }

        recent.removeAll { p.ts - it.payment.ts > SAME_SCREEN_WINDOW_MS }
        // The same success screen seen again (re-render, or the card shown again minutes later).
        // Within a few minutes the merchant may differ: it appears on the page a moment later.
        if (p.source == "screen" && recent.any {
                it.payment.source.contains("screen") && it.payment.app == p.app &&
                    it.payment.amountMinor == p.amountMinor &&
                    (it.payment.merchant == p.merchant || p.ts - it.payment.ts <= SAME_PAYMENT_WINDOW_MS)
            }
        ) return

        val match = recent.firstOrNull {
            it.payment.app == p.app && it.payment.direction == p.direction &&
                it.payment.amountMinor == p.amountMinor && p.ts - it.payment.ts <= SAME_PAYMENT_WINDOW_MS &&
                !it.payment.source.contains(p.source)
        }

        File(ctx.filesDir, FILE_NAME).appendText(LocalCrypto.seal(p.toJson().toString()) + "\n")
        WidgetRefresh.afterCapture(ctx)

        val merged = if (match != null) {
            p.copy(merchant = p.merchant ?: match.payment.merchant, source = "${match.payment.source}+${p.source}")
        } else {
            p
        }
        val notificationId = match?.notificationId ?: nextNotificationId++
        if (match != null) recent.remove(match)
        recent.addLast(Recent(merged, notificationId))
        notifyRecorded(ctx, merged, notificationId)
    }

    private val seenBillRows = LinkedHashSet<String>()

    /**
     * Rows of Alipay's Bills list. Written quietly (no "recorded" notification): most of them are
     * already known; the app merges them and only adds what's missing (auto-debits, bike rides…).
     */
    @Synchronized
    fun recordBills(ctx: Context, rows: List<CapturedPayment>) {
        val fresh = rows.filter { seenBillRows.add(it.raw) }
        if (fresh.isEmpty()) return
        while (seenBillRows.size > 500) seenBillRows.remove(seenBillRows.first())
        File(ctx.filesDir, FILE_NAME).appendText(fresh.joinToString("") { LocalCrypto.seal(it.toJson().toString()) + "\n" })
        WidgetRefresh.afterCapture(ctx)
    }

    /** Raw append for WeChat transfer prompts and their answers (see [TransferPrompts]). */
    @Synchronized
    fun append(ctx: Context, p: CapturedPayment) {
        File(ctx.filesDir, FILE_NAME).appendText(LocalCrypto.seal(p.toJson().toString()) + "\n")
        WidgetRefresh.afterCapture(ctx)
    }

    @Synchronized
    fun consume(ctx: Context): String {
        val f = File(ctx.filesDir, FILE_NAME)
        if (!f.exists()) return ""
        val text = LocalCrypto.openAll(f.readText())
        f.delete()
        return text
    }

    fun canNotify(ctx: Context) = Build.VERSION.SDK_INT < 33 ||
        ctx.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED

    fun ensureChannel(ctx: Context): NotificationManager {
        val nm = ctx.getSystemService(NotificationManager::class.java)
        if (nm.getNotificationChannel(CHANNEL_ID) == null) {
            nm.createNotificationChannel(
                NotificationChannel(CHANNEL_ID, NativeStrings.t(ctx, "channel"), NotificationManager.IMPORTANCE_DEFAULT).apply {
                    setSound(null, null)
                    enableVibration(false)
                }
            )
        }
        return nm
    }

    private fun notifyRecorded(ctx: Context, p: CapturedPayment, id: Int) {
        if (!canNotify(ctx)) return
        val nm = ensureChannel(ctx)
        val sign = if (p.direction == "income") "+" else "−"
        val source = when (p.app) { "alipay" -> "Alipay"; "wechat" -> "WeChat"; "gwallet" -> "Google Wallet"; else -> p.method ?: p.app }
        val title = NativeStrings.t(ctx, "recorded", "$sign${money(p.amountMinor, p.currency)}")
        val text = listOfNotNull(p.merchant, source).joinToString(" · ") + " — " + NativeStrings.t(ctx, "tap_to_check")

        val intent = Intent(ctx, MainActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        val pi = PendingIntent.getActivity(ctx, 0, intent, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)

        val b = android.app.Notification.Builder(ctx, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_stat_payment)
            .setContentTitle(title)
            .setContentText(text)
            .setContentIntent(pi)
            .setAutoCancel(true)
            .setOnlyAlertOnce(true)
        // Paid for everyone? Split right from the notification.
        if (p.direction == "expense") {
            // ÷2, "For a friend" (I paid it all for them), "Split…" (any other way). parts = 0 means a friend.
            b.addAction(android.app.Notification.Action.Builder(null, "÷2", SplitActions.splitIntent(ctx, p, 2, id)).build())
            b.addAction(android.app.Notification.Action.Builder(null, NativeStrings.t(ctx, "for_friend"), SplitActions.splitIntent(ctx, p, 0, id)).build())
            // No payee (WeChat Pay): "Where?" first, so the category can be remembered for it.
            if (p.merchant == null) b.addAction(SplitActions.payeeAction(ctx, p, id))
            else b.addAction(android.app.Notification.Action.Builder(null, NativeStrings.t(ctx, "split_more"), SplitActions.moreIntent(ctx, p, id)).build())
        }
        nm.notify(id, b.build())
    }

    private val SYMBOLS = mapOf("CNY" to "¥", "RUB" to "₽", "KZT" to "₸", "USD" to "$", "EUR" to "€")

    fun money(minor: Long, currency: String): String =
        BigDecimal.valueOf(minor, 2).stripTrailingZeros().toPlainString() + " " + (SYMBOLS[currency] ?: currency)
}
