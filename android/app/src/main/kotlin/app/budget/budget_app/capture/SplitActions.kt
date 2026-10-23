package app.budget.budget_app.capture

import android.app.Notification
import android.app.PendingIntent
import android.app.RemoteInput
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import app.budget.budget_app.MainActivity
import app.budget.budget_app.NativeStrings
import app.budget.budget_app.R

/**
 * Buttons on the "Recorded" notification: "÷2", "For a friend" (parts = 0) and "Split…" — or, when
 * the payee is unknown (WeChat Pay doesn't name it), "Where?" with a text reply first. ÷N / friend /
 * payee write an event to the inbox for the app; "Split…" opens the app's split sheet.
 */
object SplitActions {
    private const val ACTION_SPLIT = "app.budget.budget_app.SPLIT"
    private const val ACTION_PAYEE = "app.budget.budget_app.PAYEE"
    const val EXTRA_OPEN_SPLIT = "openSplit"
    private const val EXTRA_PARTS = "parts"
    private const val EXTRA_APP = "app"
    private const val EXTRA_AMOUNT = "amount"
    private const val EXTRA_CURRENCY = "currency"
    private const val EXTRA_TS = "ts"
    private const val EXTRA_NOTIFICATION = "notificationId"
    private const val KEY_PAYEE = "payee"

    private fun fill(i: Intent, p: CapturedPayment, notificationId: Int) = i
        .putExtra(EXTRA_APP, p.app).putExtra(EXTRA_AMOUNT, p.amountMinor).putExtra(EXTRA_CURRENCY, p.currency)
        .putExtra(EXTRA_TS, p.ts).putExtra(EXTRA_NOTIFICATION, notificationId)

    fun splitIntent(ctx: Context, p: CapturedPayment, parts: Int, notificationId: Int): PendingIntent {
        val i = fill(Intent(ctx, SplitReceiver::class.java).setAction(ACTION_SPLIT).putExtra(EXTRA_PARTS, parts), p, notificationId)
        return PendingIntent.getBroadcast(
            ctx, notificationId * 10 + parts, i, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
    }

    fun moreIntent(ctx: Context, p: CapturedPayment, notificationId: Int): PendingIntent {
        val i = fill(Intent(ctx, MainActivity::class.java).putExtra(EXTRA_OPEN_SPLIT, true), p, notificationId)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        return PendingIntent.getActivity(
            ctx, notificationId * 10 + 9, i, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
    }

    /** "Where?" with a text field: the payee of a payment that came without one. */
    fun payeeAction(ctx: Context, p: CapturedPayment, notificationId: Int): Notification.Action {
        val i = fill(Intent(ctx, SplitReceiver::class.java).setAction(ACTION_PAYEE), p, notificationId)
        val pi = PendingIntent.getBroadcast(
            ctx, notificationId * 10 + 8, i, PendingIntent.FLAG_MUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val input = RemoteInput.Builder(KEY_PAYEE).setLabel(NativeStrings.t(ctx, "payee_label")).build()
        return Notification.Action.Builder(null, NativeStrings.t(ctx, "payee_ask"), pi).addRemoteInput(input).build()
    }

    /** "Split…" pressed: what the Flutter side should open (read once via the channel). */
    fun pendingFrom(intent: Intent?): Map<String, Any>? {
        if (intent?.getBooleanExtra(EXTRA_OPEN_SPLIT, false) != true) return null
        return mapOf(
            "type" to "split",
            "app" to (intent.getStringExtra(EXTRA_APP) ?: ""),
            "amountMinor" to intent.getLongExtra(EXTRA_AMOUNT, 0),
            "ts" to intent.getLongExtra(EXTRA_TS, 0),
        )
    }

    fun handle(ctx: Context, intent: Intent) {
        if (intent.action == ACTION_PAYEE) onPayee(ctx, intent) else onSplit(ctx, intent)
    }

    private fun onPayee(ctx: Context, intent: Intent) {
        val payee = RemoteInput.getResultsFromIntent(intent)?.getCharSequence(KEY_PAYEE)?.toString()?.trim()
        val id = intent.getIntExtra(EXTRA_NOTIFICATION, 0)
        val amount = intent.getLongExtra(EXTRA_AMOUNT, 0)
        val currency = intent.getStringExtra(EXTRA_CURRENCY) ?: "CNY"
        if (!payee.isNullOrEmpty()) {
            CaptureInbox.append(
                ctx,
                CapturedPayment(
                    source = "payee", app = intent.getStringExtra(EXTRA_APP) ?: "", direction = "expense",
                    amountMinor = amount, currency = currency, merchant = payee.take(60), method = null,
                    ts = intent.getLongExtra(EXTRA_TS, System.currentTimeMillis()), raw = "payee",
                ),
            )
        }
        val n = Notification.Builder(ctx, CaptureInbox.CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_stat_payment)
            .setContentTitle(NativeStrings.t(ctx, "recorded", "−" + CaptureInbox.money(amount, currency)))
            .setContentText(payee ?: "")
            .setTimeoutAfter(5000)
            .setAutoCancel(true)
            .build()
        CaptureInbox.ensureChannel(ctx).notify(id, n)
    }

    private fun onSplit(ctx: Context, intent: Intent) {
        val parts = intent.getIntExtra(EXTRA_PARTS, 2)
        val amount = intent.getLongExtra(EXTRA_AMOUNT, 0)
        val currency = intent.getStringExtra(EXTRA_CURRENCY) ?: "CNY"
        CaptureInbox.append(
            ctx,
            CapturedPayment(
                source = "split", app = intent.getStringExtra(EXTRA_APP) ?: "", direction = "expense",
                amountMinor = amount, currency = currency, merchant = null, method = null,
                ts = intent.getLongExtra(EXTRA_TS, System.currentTimeMillis()), raw = "split", promptId = parts,
            )
        )
        val id = intent.getIntExtra(EXTRA_NOTIFICATION, 0)
        val share = if (parts > 0) (amount + parts - 1) / parts else 0L
        val n = Notification.Builder(ctx, CaptureInbox.CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_stat_payment)
            .setContentTitle(
                if (parts > 0) NativeStrings.t(ctx, "split_done", parts, CaptureInbox.money(share, currency))
                else NativeStrings.t(ctx, "for_friend_done", CaptureInbox.money(amount, currency)),
            )
            .setTimeoutAfter(5000)
            .setAutoCancel(true)
            .build()
        CaptureInbox.ensureChannel(ctx).notify(id, n)
    }
}

class SplitReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) = SplitActions.handle(context, intent)
}
