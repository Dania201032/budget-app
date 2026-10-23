package app.budget.budget_app.capture

import android.app.Notification
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification

/**
 * Turns payment notifications into captured payments: Alipay "交易提醒", WeChat Pay, WeChat transfer
 * chat notices, and Russian/Kazakh bank pushes and SMS (whatever country/language is chosen).
 */
class PaymentNotificationListener : NotificationListenerService() {
    private val seen = LinkedHashSet<String>()

    /** Last payment read from each notification (WeChat updates its chat notification in place). */
    private val lastByKey = HashMap<String, CapturedPayment>()

    private fun isRepost(key: String, p: CapturedPayment): Boolean {
        val prev = lastByKey.put(key, p)
        if (lastByKey.size > 200) lastByKey.clear()
        return prev != null && prev.amountMinor == p.amountMinor && prev.direction == p.direction &&
            p.ts - prev.ts in 0..REPOST_WINDOW_MS
    }

    companion object {
        private const val REPOST_WINDOW_MS = 3 * 60_000L
    }

    override fun onNotificationPosted(sbn: StatusBarNotification) {
        val pkg = sbn.packageName ?: return
        if (pkg == packageName) return
        val ex = sbn.notification?.extras ?: return
        // Ongoing/group-summary notifications repeat or summarize others.
        if (sbn.notification.flags and Notification.FLAG_GROUP_SUMMARY != 0) return
        val title = ex.getCharSequence(Notification.EXTRA_TITLE)?.toString() ?: ""
        val text = ex.getCharSequence(Notification.EXTRA_BIG_TEXT)?.toString()
            ?: ex.getCharSequence(Notification.EXTRA_TEXT)?.toString() ?: ""

        if (CapturedPayment.appFor(pkg) != null) {
            PaymentParsers.parseNotification(pkg, title, text, sbn.postTime)?.let {
                if (!isRepost(sbn.key, it)) CaptureInbox.record(this, it)
                return
            }
            if (pkg == "com.tencent.mm") {
                PaymentParsers.parseTransferNotice(title, text)?.let { TransferPrompts.onTransfer(this, it, sbn.postTime) }
            }
            return
        }
        val verdict = BankParsers.classify(pkg, title, text, sbn.postTime) ?: return
        // An updated or re-posted notification is the same operation.
        if (!seen.add("${sbn.key}|$title|$text")) return
        while (seen.size > 200) seen.remove(seen.first())
        val bank = BankParsers.bankFor(pkg, title)!!
        val isSms = pkg in BankParsers.SMS_APPS
        if (!isSms && pkg != EuBankParsers.GOOGLE_WALLET) PaymentAccessibilityService.rememberBank(this, pkg)
        // SMS from people are not logged; only bank senders and recognized operations.
        if (!isSms || bank.key != "sms" || verdict.payment != null) {
            BankLog.add(this, pkg, bank, title, text, sbn.postTime, verdict)
        }
        verdict.payment?.let { CaptureInbox.record(this, it) }
    }
}
