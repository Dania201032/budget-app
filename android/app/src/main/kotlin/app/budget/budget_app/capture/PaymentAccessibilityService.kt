package app.budget.budget_app.capture

import android.accessibilityservice.AccessibilityService
import android.content.Context
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo

/**
 * Reads the payment result screen in Alipay / WeChat, Alipay's Bills list and the operations history
 * of bank apps (the only packages it receives events from: res/xml/payment_accessibility.xml plus
 * banks that sent a notification, see [rememberBank]). Nothing is stored except detected payments.
 */
class PaymentAccessibilityService : AccessibilityService() {

    companion object {
        private const val DEBOUNCE_MS = 350L
        private const val MAX_WAIT_MS = 1500L
        private const val MAX_NODES = 1500
        private const val PREFS = "capture"
        private const val KEY_BANKS = "bank_packages"

        @Volatile
        private var instance: PaymentAccessibilityService? = null

        /** A bank app not in the static list (found by its notifications): start reading its screens too. */
        fun rememberBank(ctx: Context, pkg: String) {
            val prefs = ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            val known = prefs.getStringSet(KEY_BANKS, emptySet())!!
            if (pkg in known) return
            prefs.edit().putStringSet(KEY_BANKS, known + pkg).apply()
            instance?.let { s -> Handler(Looper.getMainLooper()).post { s.updatePackages() } }
        }
    }

    private val handler = Handler(Looper.getMainLooper())
    private var pendingSince = 0L
    private var lastPackage = ""
    private var lastScreenClass = ""
    private var cashier: PaymentParsers.CashierInfo? = null
    private val scanRunnable = Runnable { scan() }

    override fun onServiceConnected() {
        super.onServiceConnected()
        instance = this
        updatePackages()
    }

    override fun onDestroy() {
        if (instance === this) instance = null
        super.onDestroy()
    }

    private fun updatePackages() {
        val info = serviceInfo ?: return
        val extra = getSharedPreferences(PREFS, Context.MODE_PRIVATE).getStringSet(KEY_BANKS, emptySet())!!
        val all = (info.packageNames?.toSet() ?: emptySet()) + extra
        if (info.packageNames != null && all.size == info.packageNames.size) return
        info.packageNames = all.toTypedArray()
        serviceInfo = info
    }

    // Google Wallet only notifies; its own list would duplicate the banks' histories.
    private fun isBank(pkg: String) = pkg !in BankParsers.SMS_APPS && pkg != EuBankParsers.GOOGLE_WALLET &&
        BankParsers.bankFor(pkg, "") != null
    private fun watched(pkg: String) = CapturedPayment.appFor(pkg) != null || isBank(pkg)

    override fun onAccessibilityEvent(event: AccessibilityEvent) {
        val pkg = event.packageName?.toString() ?: return
        if (!watched(pkg)) return
        lastPackage = pkg
        if (event.eventType == AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED) {
            val cls = event.className?.toString() ?: ""
            if (!cls.startsWith("android.")) lastScreenClass = cls
        }
        val now = SystemClock.uptimeMillis()
        if (pendingSince == 0L) pendingSince = now
        handler.removeCallbacks(scanRunnable)
        if (now - pendingSince >= MAX_WAIT_MS) scan() else handler.postDelayed(scanRunnable, DEBOUNCE_MS)
    }

    private fun scan() {
        pendingSince = 0L
        val pkg = lastPackage
        val texts = collectTexts(pkg)
        if (texts.isEmpty()) return
        val now = System.currentTimeMillis()

        if (isBank(pkg)) {
            val rows = BankHistory.parse(pkg, texts, now)
            if (rows.isNotEmpty()) CaptureInbox.recordBills(this, rows)
            return
        }

        val billRows = PaymentParsers.parseBillRows(texts, now)
        if (billRows.isNotEmpty()) {
            CaptureInbox.recordBills(this, billRows)
            return
        }
        PaymentParsers.parseCashier(texts, now)?.let {
            cashier = it
            CaptureInbox.lastCashier = it
        }
        PaymentParsers.parseSuccessScreen(pkg, lastScreenClass, texts, now, cashier)?.let {
            CaptureInbox.record(this, it)
        }
    }

    private fun collectTexts(pkg: String): List<String> {
        val roots = mutableListOf<AccessibilityNodeInfo>()
        try {
            for (w in windows) {
                val r = w.root ?: continue
                if (r.packageName?.toString() == pkg) roots.add(r)
            }
        } catch (_: Exception) {
        }
        if (roots.isEmpty()) rootInActiveWindow?.takeIf { watched(it.packageName?.toString() ?: "") }?.let { roots.add(it) }

        val out = mutableListOf<String>()
        var count = 0
        val stack = ArrayDeque<AccessibilityNodeInfo>()
        roots.forEach { stack.addLast(it) }
        while (stack.isNotEmpty() && count < MAX_NODES) {
            val n = stack.removeLast()
            count++
            if (n.isPassword) continue
            n.text?.toString()?.trim()?.takeIf { it.isNotEmpty() }?.let { out.add(it.take(200)) }
            n.contentDescription?.toString()?.trim()?.takeIf { it.isNotEmpty() }?.let { out.add("[desc] " + it.take(200)) }
            for (i in n.childCount - 1 downTo 0) n.getChild(i)?.let { stack.addLast(it) }
        }
        return out
    }

    override fun onInterrupt() {}
}
