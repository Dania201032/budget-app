package app.budget.budget_app.capture

import org.json.JSONObject
import java.math.BigDecimal

/** A payment detected on the phone (payment screen or notification), before it becomes a transaction. */
data class CapturedPayment(
    /**
     * "screen" | "notification" | "bill" (a row of Alipay's Bills list) |
     * "prompt" (WeChat transfer without amount, user is asked) | "prompt_answer" (amount typed for a prompt).
     */
    val source: String,
    /** "alipay", "wechat", ... */
    val app: String,
    /** "expense" or "income". */
    val direction: String,
    val amountMinor: Long,
    val currency: String,
    val merchant: String?,
    val method: String?,
    val ts: Long,
    val raw: String,
    /** Category as named by the payment app (Alipay Bills: "Food", "Transport"…). */
    val category: String? = null,
    /** Links a "prompt" and its "prompt_answer". */
    val promptId: Int? = null,
) {
    fun toJson(): JSONObject = JSONObject().apply {
        put("source", source)
        put("app", app)
        put("direction", direction)
        put("amountMinor", amountMinor)
        put("currency", currency)
        put("merchant", merchant ?: JSONObject.NULL)
        put("method", method ?: JSONObject.NULL)
        put("ts", ts)
        put("raw", raw)
        put("category", category ?: JSONObject.NULL)
        put("promptId", promptId ?: JSONObject.NULL)
    }

    companion object {
        /** "1,234.50" -> 123450 */
        fun parseMinor(amount: String): Long? = try {
            BigDecimal(amount.replace(",", "").trim()).movePointRight(2).toLong()
        } catch (_: NumberFormatException) {
            null
        }

        fun appFor(pkg: String): String? = when (pkg) {
            "com.eg.android.AlipayGphone" -> "alipay"
            "com.tencent.mm" -> "wechat"
            else -> null
        }
    }
}
