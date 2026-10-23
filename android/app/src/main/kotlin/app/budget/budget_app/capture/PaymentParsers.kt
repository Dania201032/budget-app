package app.budget.budget_app.capture

import java.util.Calendar

/**
 * Parsers for WeChat/Alipay payment screens and notifications.
 * Formats were taken from real captures (Alipay, English UI, Oct 2026), e.g. success screen texts:
 *   ["[desc] Payment Successful￥50.00", "Payment Successful", "50.00", "全家便利店", "￥50.00",
 *    "Payment method", "Balance", "Done", "[desc] Home", "Home"]
 * and notification: title "交易提醒", text "你有一笔50.00元的支出，点击领取12个支付宝积分。"
 */
object PaymentParsers {

    private val SUCCESS_WORDS = listOf(
        "支付成功", "付款成功", "转账成功", "交易成功",
        "Payment Successful", "Paid Successfully", "Transfer Successful", "Payment successful",
    )
    private val SCREEN_AMOUNT_RE = Regex("[¥￥]\\s?(\\d{1,3}(?:,\\d{3})*(?:\\.\\d{1,2})?|\\d+(?:\\.\\d{1,2})?)")
    private val NUMBER_ONLY_RE = Regex("^[¥￥]?\\s?[\\d.,]+$")
    private val METHOD_LABELS = setOf("Payment method", "付款方式", "支付方式")
    private val NOT_MERCHANT = setOf(
        "Payment method", "付款方式", "支付方式", "Balance", "余额", "Done", "完成", "Home", "首页",
        "Close", "关闭", "返回", "Back", "View bill", "查看账单", "账单详情", "Details",
        "Translate", "翻译", "Pay / Receive", "收付款", "General Member", "Paying...", "Pay vendor",
        "Receive", "收钱", "Transfer", "转账", "Default payment method", "Tap to view payment code",
        "Alipay Tap", "Account", "Payment tools",
    )

    /** Screens where we never look for payments (chat lists and conversations). */
    private val IGNORED_SCREENS = Regex("LauncherUI|Chatting", RegexOption.IGNORE_CASE)

    data class CashierInfo(val merchant: String?, val amountMinor: Long?, val ts: Long)

    /**
     * Cashier (confirmation) screen, before the password: we remember its merchant as a fallback
     * in case the success screen doesn't show it. Alipay: "[desc] Payment amount: 50.00 yuan".
     */
    private val CASHIER_AMOUNT_RE = Regex("Payment amount:\\s*([\\d.,]+)|付款金额[:：]?\\s*([\\d.,]+)")

    fun parseCashier(texts: List<String>, now: Long): CashierInfo? {
        val joined = texts.joinToString(" | ")
        val m = CASHIER_AMOUNT_RE.find(joined) ?: return null
        val amount = (m.groupValues[1].ifEmpty { m.groupValues[2] }).let { CapturedPayment.parseMinor(it) }
        val merchant = texts.firstOrNull { isMerchantCandidate(it) }?.let { cleanMerchant(it) }
        return CashierInfo(merchant, amount, now)
    }

    /** "Transfer to KIRILL(* KIRILL)" -> "KIRILL"; "转账给张三(*三)" -> "张三". */
    fun cleanMerchant(s: String): String = s
        .replaceFirst(Regex("^(Transfer to|转账给|付款给|向)\\s*"), "")
        .replace(Regex("[(（]\\s*\\*[^)）]*[)）]"), "")
        .trim()

    fun parseSuccessScreen(
        pkg: String,
        screenClass: String,
        texts: List<String>,
        now: Long,
        cashier: CashierInfo?,
    ): CapturedPayment? {
        val app = CapturedPayment.appFor(pkg) ?: return null
        if (IGNORED_SCREENS.containsMatchIn(screenClass)) return null
        val joined = texts.joinToString(" | ")
        if (SUCCESS_WORDS.none { joined.contains(it, ignoreCase = true) }) return null

        // The merchant and amount follow the success title ("Payment Successful", "19.00", "申梦上荷（吉浦路店）").
        // The payment-code success card is drawn over the "Pay / Receive" page, so texts *before*
        // the title belong to that page and are only a last resort.
        val titleIdx = texts.indexOfFirst { t -> !t.startsWith("[desc]") && SUCCESS_WORDS.any { t.contains(it, ignoreCase = true) } }
        val nearTitle = texts.drop(maxOf(titleIdx - 1, 0)).joinToString(" | ")
        val amountMinor = (SCREEN_AMOUNT_RE.find(nearTitle) ?: SCREEN_AMOUNT_RE.find(joined))?.groupValues?.get(1)
            ?.let { CapturedPayment.parseMinor(it) } ?: return null

        var merchant = texts.drop(titleIdx + 1).firstOrNull { isMerchantCandidate(it) }
            ?: texts.firstOrNull { isMerchantCandidate(it) }
        merchant = merchant?.let { cleanMerchant(it) }
        if (merchant == null && cashier != null && cashier.amountMinor == amountMinor &&
            now - cashier.ts < 10 * 60_000
        ) {
            merchant = cashier.merchant
        }

        val methodIdx = texts.indexOfFirst { it in METHOD_LABELS }
        val method = texts.getOrNull(methodIdx + 1)?.takeIf { methodIdx >= 0 && !it.startsWith("[desc]") }

        return CapturedPayment(
            source = "screen",
            app = app,
            direction = "expense",
            amountMinor = amountMinor,
            currency = "CNY",
            merchant = merchant,
            method = method,
            ts = now,
            raw = joined.take(1000),
        )
    }

    private fun isMerchantCandidate(t: String): Boolean {
        if (t.startsWith("[desc]")) return false
        if (t.length !in 2..40) return false
        if (t in NOT_MERCHANT) return false
        if (NUMBER_ONLY_RE.matches(t)) return false
        if (SUCCESS_WORDS.any { t.contains(it, ignoreCase = true) }) return false
        if (t.contains("***")) return false // masked account / phone
        return true
    }

    // --- Alipay Bills list (账单) ---
    // Real row (Oct 13): "哈啰出行车费，-2.50元，Auto debit successful，TransportAuto debit successful，，Today 13:05"
    //                    "申梦上荷（吉浦路店），-19.00元，，Food，，Today 11:59"

    private val BILLS_MARKERS = setOf("Search transaction history", "搜索交易记录")
    private val BILL_ROW_RE = Regex("^(.+?)，([+-]?)([\\d,]+(?:\\.\\d{1,2})?)元，(.*)$")
    private val BILL_SKIP_RE = Regex("关闭|失败|Closed|Failed|Cancelled|已取消", RegexOption.IGNORE_CASE)
    private val TRAILING_DATETIME_RE = Regex("-\\d{4}-\\d{2}-\\d{2} \\d{2}:\\d{2}(:\\d{2})?$")

    fun isBillsScreen(texts: List<String>) = texts.any { it in BILLS_MARKERS }

    /** Rows of the Bills list visible on screen; [now] resolves "Today"/"Yesterday". */
    fun parseBillRows(texts: List<String>, now: Long): List<CapturedPayment> {
        if (!isBillsScreen(texts)) return emptyList()
        val out = mutableListOf<CapturedPayment>()
        for (t in texts) {
            val m = BILL_ROW_RE.find(t) ?: continue
            val rest = m.groupValues[4].split('，')
            if (BILL_SKIP_RE.containsMatchIn(m.groupValues[4])) continue
            val ts = parseBillTime(rest.last().trim(), now) ?: continue
            val amount = CapturedPayment.parseMinor(m.groupValues[3]) ?: continue
            val status = rest.getOrNull(0)?.trim().orEmpty()
            // The category cell repeats the status: "TransportAuto debit successful".
            val category = rest.getOrNull(1)?.removeSuffix(status)?.trim()?.takeIf { it.isNotEmpty() }
            out.add(
                CapturedPayment(
                    source = "bill",
                    app = "alipay",
                    direction = if (m.groupValues[2] == "+") "income" else "expense",
                    amountMinor = amount,
                    currency = "CNY",
                    merchant = cleanBillMerchant(m.groupValues[1]),
                    // The Bills list shows a status ("Auto debit successful"), not how it was paid.
                    method = null,
                    ts = ts,
                    raw = t,
                    category = category,
                )
            )
        }
        return out
    }

    /** "收款-KIRILL" -> "KIRILL", "扫收钱码付款-给韩学林" -> "韩学林", "上海公交-20路-2026-10-11 10:49:53" -> "上海公交-20路". */
    fun cleanBillMerchant(s: String): String = s.trim()
        .replace(TRAILING_DATETIME_RE, "")
        .replaceFirst(Regex("^(收款-|扫收钱码付款-给|转账-|转账给)"), "")
        .trim()

    /** "Today 13:05", "昨天 07:50", "10-11 18:47", "2025-12-30 18:47" -> epoch ms (local time). */
    fun parseBillTime(s: String, now: Long): Long? {
        val cal = Calendar.getInstance().apply { timeInMillis = now }
        fun at(y: Int, mo: Int, d: Int, h: Int, mi: Int): Long = Calendar.getInstance().apply {
            clear()
            set(y, mo - 1, d, h, mi, 0)
        }.timeInMillis
        fun Calendar.at(h: Int, mi: Int) = at(get(Calendar.YEAR), get(Calendar.MONTH) + 1, get(Calendar.DAY_OF_MONTH), h, mi)

        Regex("^(Today|今天)\\s+(\\d{1,2}):(\\d{2})$").find(s)?.let {
            return cal.at(it.groupValues[2].toInt(), it.groupValues[3].toInt())
        }
        Regex("^(Yesterday|昨天)\\s+(\\d{1,2}):(\\d{2})$").find(s)?.let {
            val y = (cal.clone() as Calendar).apply { add(Calendar.DAY_OF_MONTH, -1) }
            return y.at(it.groupValues[2].toInt(), it.groupValues[3].toInt())
        }
        Regex("^(\\d{4})-(\\d{1,2})-(\\d{1,2})\\s+(\\d{1,2}):(\\d{2})$").find(s)?.let { m ->
            val v = m.groupValues.drop(1).map { it.toInt() }
            return at(v[0], v[1], v[2], v[3], v[4])
        }
        Regex("^(\\d{1,2})-(\\d{1,2})\\s+(\\d{1,2}):(\\d{2})$").find(s)?.let { m ->
            val v = m.groupValues.drop(1).map { it.toInt() }
            val year = cal.get(Calendar.YEAR)
            var ts = at(year, v[0], v[1], v[2], v[3])
            // "12-30" seen in January belongs to last year.
            if (ts > now + 86_400_000L) ts = at(year - 1, v[0], v[1], v[2], v[3])
            return ts
        }
        return null
    }

    // --- WeChat transfers (chat notifications, no amount) ---
    // Real (Oct 13, English WeChat): title "Alex", text "[Transfer] Accept transfer" (to me, waiting)
    // and "[Transfer] Accepted" (the friend accepted my transfer).

    private val TRANSFER_RE = Regex("^(?:(.+?):\\s*)?\\[(Transfer|转账)\\]\\s*(.*)$", RegexOption.IGNORE_CASE)
    private val TRANSFER_IN_RE = Regex("Accept transfer|请收款|待收款|确认收款|请确认", RegexOption.IGNORE_CASE)
    private val TRANSFER_OUT_RE = Regex("^Accepted|已收款|已被接收|已接收", RegexOption.IGNORE_CASE)

    data class TransferNotice(val contact: String, val direction: String)

    fun parseTransferNotice(title: String, text: String): TransferNotice? {
        val m = TRANSFER_RE.find(text.trim()) ?: return null
        // Group chats: title is the group, text is "Name: [Transfer] …".
        val contact = m.groupValues[1].ifBlank { title }.trim()
        val status = m.groupValues[3].trim()
        val direction = when {
            TRANSFER_IN_RE.containsMatchIn(status) -> "income"
            TRANSFER_OUT_RE.containsMatchIn(status) -> "expense"
            else -> return null
        }
        return TransferNotice(contact, direction)
    }

    // --- Notifications ---

    private val ALIPAY_TXN_RE = Regex("一笔\\s*([\\d,]+(?:\\.\\d{1,2})?)\\s*元的(支出|收入)")
    private val ALIPAY_RECEIVED_RE = Regex("(?:到账|收款|收到)[^\\d]{0,12}([\\d,]+(?:\\.\\d{1,2})?)\\s*元")
    // English WeChat shows the service as "Weixin Pay" (seen on a real device: "¥5.00 paid").
    private val WECHAT_PAY_TITLE_RE = Regex("微信支付|WeChat Pay|Weixin Pay", RegexOption.IGNORE_CASE)
    private val WECHAT_AMOUNT_RE = Regex("[¥￥]\\s?([\\d,]+(?:\\.\\d{1,2})?)|([\\d,]+(?:\\.\\d{1,2})?)\\s*元")
    private val INCOME_WORDS_RE = Regex("收款|到账|收入|received|入账", RegexOption.IGNORE_CASE)

    fun parseNotification(pkg: String, title: String, text: String, now: Long): CapturedPayment? {
        val all = "$title | $text"
        return when (pkg) {
            "com.eg.android.AlipayGphone" -> {
                ALIPAY_TXN_RE.find(all)?.let { m ->
                    val amount = CapturedPayment.parseMinor(m.groupValues[1]) ?: return null
                    val dir = if (m.groupValues[2] == "收入") "income" else "expense"
                    return CapturedPayment("notification", "alipay", dir, amount, "CNY", null, null, now, all)
                }
                ALIPAY_RECEIVED_RE.find(all)?.let { m ->
                    val amount = CapturedPayment.parseMinor(m.groupValues[1]) ?: return null
                    return CapturedPayment("notification", "alipay", "income", amount, "CNY", null, null, now, all)
                }
                null
            }
            "com.tencent.mm" -> {
                // Only WeChat Pay service notifications; never ordinary chats.
                if (!WECHAT_PAY_TITLE_RE.containsMatchIn(title)) return null
                val m = WECHAT_AMOUNT_RE.find(all) ?: return null
                val amount = CapturedPayment.parseMinor(m.groupValues[1].ifEmpty { m.groupValues[2] }) ?: return null
                val dir = if (INCOME_WORDS_RE.containsMatchIn(all)) "income" else "expense"
                CapturedPayment("notification", "wechat", dir, amount, "CNY", null, null, now, all)
            }
            else -> null
        }
    }
}
