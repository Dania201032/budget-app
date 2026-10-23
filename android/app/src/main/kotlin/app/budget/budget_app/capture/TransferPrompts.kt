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
 * WeChat transfers arrive only as chat notifications without an amount ("[Transfer] Accept transfer").
 * We record a pending transaction and ask for the amount in our own notification with an inline
 * reply field; the answer goes back to the inbox as a "prompt_answer".
 */
object TransferPrompts {
    private const val ACTION_REPLY = "app.budget.budget_app.TRANSFER_AMOUNT"
    private const val ACTION_SKIP = "app.budget.budget_app.TRANSFER_SKIP"
    private const val KEY_AMOUNT = "amount"
    private const val EXTRA_ID = "promptId"
    private const val EXTRA_CONTACT = "contact"
    private const val EXTRA_DIRECTION = "direction"
    private const val EXTRA_TS = "ts"
    private const val DEDUP_MS = 2 * 60_000L

    private val recent = mutableMapOf<String, Long>()

    @Synchronized
    fun onTransfer(ctx: Context, notice: PaymentParsers.TransferNotice, ts: Long) {
        val key = "${notice.contact}|${notice.direction}"
        // WeChat re-posts the conversation notification for every new message.
        if ((recent[key] ?: 0L) > ts - DEDUP_MS) return
        recent[key] = ts

        val id = (ts / 1000 % Int.MAX_VALUE).toInt()
        CaptureInbox.append(
            ctx,
            CapturedPayment(
                source = "prompt", app = "wechat", direction = notice.direction, amountMinor = 0, currency = "CNY",
                merchant = notice.contact, method = null, ts = ts, raw = "WeChat transfer", promptId = id,
            )
        )
        if (!CaptureInbox.canNotify(ctx)) return

        val title = if (notice.direction == "income") {
            NativeStrings.t(ctx, "transfer_from", notice.contact)
        } else {
            NativeStrings.t(ctx, "transfer_accepted", notice.contact)
        }
        fun broadcast(action: String, mutable: Boolean): PendingIntent {
            val i = Intent(ctx, TransferReplyReceiver::class.java).setAction(action)
                .putExtra(EXTRA_ID, id).putExtra(EXTRA_CONTACT, notice.contact)
                .putExtra(EXTRA_DIRECTION, notice.direction).putExtra(EXTRA_TS, ts)
            val flags = PendingIntent.FLAG_UPDATE_CURRENT or
                (if (mutable) PendingIntent.FLAG_MUTABLE else PendingIntent.FLAG_IMMUTABLE)
            return PendingIntent.getBroadcast(ctx, id * 2 + if (mutable) 0 else 1, i, flags)
        }
        val input = RemoteInput.Builder(KEY_AMOUNT).setLabel(NativeStrings.t(ctx, "amount_label") + ", ¥").build()
        val reply = Notification.Action.Builder(null, NativeStrings.t(ctx, "enter_amount"), broadcast(ACTION_REPLY, true))
            .addRemoteInput(input).build()
        val skip = Notification.Action.Builder(null, NativeStrings.t(ctx, "dont_record"), broadcast(ACTION_SKIP, false)).build()
        val open = PendingIntent.getActivity(
            ctx, 0, Intent(ctx, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
            PendingIntent.FLAG_IMMUTABLE,
        )
        val n = Notification.Builder(ctx, CaptureInbox.CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_stat_payment)
            .setContentTitle(title)
            .setContentText(NativeStrings.t(ctx, "how_much"))
            .setContentIntent(open)
            .addAction(reply)
            .addAction(skip)
            .setAutoCancel(true)
            .build()
        CaptureInbox.ensureChannel(ctx).notify(id, n)
    }

    fun handle(ctx: Context, intent: Intent) {
        val id = intent.getIntExtra(EXTRA_ID, 0)
        val nm = CaptureInbox.ensureChannel(ctx)
        if (intent.action == ACTION_SKIP) {
            CaptureInbox.append(ctx, answer(intent, 0))
            nm.cancel(id)
            return
        }
        val text = RemoteInput.getResultsFromIntent(intent)?.getCharSequence(KEY_AMOUNT)?.toString() ?: return
        val minor = parseAmount(text)
        if (minor == null) {
            // The pending transaction stays in the app's review list; replace the spinner with a hint.
            nm.notify(
                id,
                Notification.Builder(ctx, CaptureInbox.CHANNEL_ID)
                    .setSmallIcon(R.drawable.ic_stat_payment)
                    .setContentTitle(NativeStrings.t(ctx, "not_understood", text))
                    .setContentText(NativeStrings.t(ctx, "waiting_review"))
                    .setTimeoutAfter(6000)
                    .build(),
            )
            return
        }
        CaptureInbox.append(ctx, answer(intent, minor))
        val sign = if (intent.getStringExtra(EXTRA_DIRECTION) == "income") "+" else "−"
        val done = Notification.Builder(ctx, CaptureInbox.CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_stat_payment)
            .setContentTitle(NativeStrings.t(ctx, "recorded", sign + CaptureInbox.money(minor, "CNY")))
            .setContentText("${intent.getStringExtra(EXTRA_CONTACT)} · WeChat")
            .setTimeoutAfter(4000)
            .setAutoCancel(true)
            .build()
        nm.notify(id, done)
    }

    /** amountMinor = 0 means "skip this transfer". */
    private fun answer(intent: Intent, minor: Long) = CapturedPayment(
        source = "prompt_answer",
        app = "wechat",
        direction = intent.getStringExtra(EXTRA_DIRECTION) ?: "income",
        amountMinor = minor,
        currency = "CNY",
        merchant = intent.getStringExtra(EXTRA_CONTACT),
        method = null,
        ts = intent.getLongExtra(EXTRA_TS, System.currentTimeMillis()),
        raw = "WeChat transfer",
        promptId = intent.getIntExtra(EXTRA_ID, 0),
    )

    /** "12,5" / "12.50" / "¥ 20" -> minor units. */
    fun parseAmount(s: String): Long? {
        val cleaned = s.replace(Regex("[^\\d.,]"), "").replace(',', '.')
        val v = cleaned.toBigDecimalOrNull() ?: return null
        if (v.signum() <= 0) return null
        return v.movePointRight(2).toLong()
    }
}

class TransferReplyReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) = TransferPrompts.handle(context, intent)
}
