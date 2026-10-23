package app.budget.budget_app.capture

import android.content.Context
import org.json.JSONObject
import java.io.File

/**
 * The last bank notifications and what was done with each ("recorded", "promo", "code"…), kept only
 * on the phone and shown in Settings → Automatic recording, so a wrong or missed one can be seen
 * (and added by hand). One-time codes are logged without their text.
 */
object BankLog {
    private const val FILE_NAME = "bank_log.jsonl"
    private const val MAX = 100

    @Synchronized
    fun add(ctx: Context, pkg: String, bank: BankParsers.Bank, title: String, text: String, ts: Long, verdict: BankParsers.Verdict) {
        val p = verdict.payment
        val o = JSONObject()
            .put("ts", ts).put("pkg", pkg).put("app", bank.key).put("bank", bank.name).put("reason", verdict.reason)
            .put("title", if (verdict.reason == "code") "" else title.take(200))
            .put("text", if (verdict.reason == "code") "" else text.take(500))
        if (p != null) {
            o.put("direction", p.direction).put("amountMinor", p.amountMinor).put("currency", p.currency)
                .put("merchant", p.merchant ?: JSONObject.NULL)
        }
        val f = File(ctx.filesDir, FILE_NAME)
        val lines = (if (f.exists()) f.readLines().filter { it.isNotBlank() } else emptyList()).takeLast(MAX - 1) + LocalCrypto.seal(o.toString())
        f.writeText(lines.joinToString("\n", postfix = "\n"))
    }

    @Synchronized
    fun read(ctx: Context): String = File(ctx.filesDir, FILE_NAME).let { if (it.exists()) LocalCrypto.openAll(it.readText()) else "" }

    @Synchronized
    fun clear(ctx: Context) {
        File(ctx.filesDir, FILE_NAME).delete()
    }
}
