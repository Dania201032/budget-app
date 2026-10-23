package app.budget.budget_app.capture

import java.util.Calendar

/**
 * The operations history screen of a Russian/Kazakh bank app, read like Alipay's Bills: operations
 * that came without a notification (or before capture was on) are added when the user opens it.
 *
 * Bank apps differ, but every history list is days and rows under them:
 *   "Сегодня" | "Магнит" | "Супермаркеты" | "−450 ₽" | "Иван И." | "Переводы" | "+15 000 ₽" | "13 октября" | …
 * A row is the texts around one amount; the amount's sign gives the direction (unsigned = expense
 * unless the row says "Зачисление/Пополнение/…"). Amounts before the first day header (card
 * balances on the main screen) are never rows.
 */
object BankHistory {
    private data class Token(val kind: Kind, val text: String, val dayStart: Long = 0, val minutes: Int = -1,
                             val sign: Int = 0, val amountMinor: Long = 0, val currency: String = "")

    private enum class Kind { DAY, TIME, AMOUNT, TEXT }

    private val MONTHS = listOf(
        "январь|января|янв|january|jan|қаңтар|januar|jänner|januari",
        "февраль|февраля|фев|february|feb|ақпан|februar|februari",
        "март|марта|мар|march|mar|наурыз|märz|maerz|mär|maart|mrt",
        "апрель|апреля|апр|april|apr|сәуір",
        "май|мая|may|мамыр|mai|mei",
        "июнь|июня|июн|june|jun|маусым|juni",
        "июль|июля|июл|july|jul|шілде|juli",
        "август|августа|авг|august|aug|тамыз|augustus",
        "сентябрь|сентября|сен|сент|september|sep|sept|қыркүйек",
        "октябрь|октября|окт|october|oct|қазан|oktober|okt",
        "ноябрь|ноября|ноя|нояб|november|nov|қараша",
        "декабрь|декабря|дек|december|dec|желтоқсан|dezember|dez",
    ).map { it.split('|').toSet() }
    private val MONTH_WORD = "([а-яёәіңғүұқөһa-zäöü]{3,12})\\.?"
    // "13 октября", "13. Oktober", "13 oktober 2026"
    private val DAY_MONTH_RE = Regex("(?<!\\d)(\\d{1,2})\\.?\\s+$MONTH_WORD(?:\\s+(\\d{4}))?", RegexOption.IGNORE_CASE)
    private val MONTH_DAY_RE = Regex("(?<![а-яёa-zäöü])$MONTH_WORD\\s+(\\d{1,2})(?!\\d)(?:,?\\s+(\\d{4}))?", RegexOption.IGNORE_CASE)
    private val NUMERIC_DATE_RE = Regex("^(\\d{1,2})[./-](\\d{1,2})(?:[./-](\\d{2,4}))?(?:,?\\s+(\\d{1,2}):(\\d{2}))?$")
    private val TODAY_RE = Regex("^(сегодня|today|бүгін|heute|vandaag)(?![а-яёa-z])", RegexOption.IGNORE_CASE)
    private val YESTERDAY_RE = Regex("^(вчера|yesterday|кеше|gestern|gisteren)(?![а-яёa-z])", RegexOption.IGNORE_CASE)
    private val TIME_RE = Regex("(?<!\\d)([01]?\\d|2[0-3]):([0-5]\\d)(?!\\d)")

    private const val CUR = "₽|руб\\.?|р\\.|р|RUB|₸|тг|KZT|\\$|USD|€|EUR|¥|CNY"
    private val AMOUNT_RE = Regex(
        "^([+−–-])?\\s?(?:($CUR)\\s?)?(\\d{1,3}(?:[\\s  \\u202F]\\d{3})+|\\d+)(?:[.,](\\d{1,2}))?\\s?($CUR)?$",
        RegexOption.IGNORE_CASE,
    )

    private val FAILED_RE = Regex(
        "отклон|отмен[её]н|не выполн|ошибка|отказ|declined|failed|cancel|abgelehnt|storniert|fehlgeschlagen|" +
            "geweigerd|mislukt|geannuleerd|afgewezen",
        RegexOption.IGNORE_CASE,
    )
    private val INCOME_RE = Regex(
        "зачислен|поступлен|пополнен|входящ|возврат|кешб[эе]к|зарплат|перевод от|получен|түсті|толықтыр|refund|received|top[- ]?up|" +
            "gutschrift|eingang|erhalten|erstattung|gehalt|bijschrijving|ontvangen|terugbetaling|storting|salaris",
        RegexOption.IGNORE_CASE,
    )
    private val NOT_MERCHANT_RE = Regex(
        "^(выполнен[оа]?|исполнен[оа]?|успешно|в обработке|обрабатывается|ожидает|списано|зачислено|" +
            "показать (все|ещё|еще)|все операции|история|операции|фильтр|поиск|done|pending|completed|" +
            "vorgemerkt|gebucht|ausstehend|in bearbeitung|alle umsätze|umsätze|suche|in behandeling|verwerkt|" +
            "transacties|zoeken|bij|af)$|" +
            "^[•*·.\\s]*\\d{4}$|(карта|card|karte|kaart|счёт|счет|мир|visa|mastercard)\\s*[•*·.]+\\s*\\d{4}",
        RegexOption.IGNORE_CASE,
    )

    /** Bank categories that some apps print above the payee ("Входящие переводы" / "Иван И."). */
    private val GENERIC_RE = Regex(
        "((входящие|исходящие)\\s+)?(переводы?|пополнения?|зачисления?|поступления?|снятие наличных|покупки|оплата услуг|прочее|другое|" +
            "аударымдар|transfers?|top-?ups?|incoming|outgoing|kartenzahlung|lastschrift|überweisung|gutschrift|dauerauftrag|" +
            "betaling|pinbetaling|overboeking|incasso|bijschrijving|afschrijving|ideal|betaalverzoek|card payment|direct debit)",
        RegexOption.IGNORE_CASE,
    )

    /** History rows on this screen; empty when it isn't a history list. */
    fun parse(pkg: String, texts: List<String>, now: Long): List<CapturedPayment> {
        val bank = BankParsers.bankFor(pkg, "") ?: return emptyList()
        if (pkg in BankParsers.SMS_APPS) return emptyList()
        // Apps expose a row either as separate texts or as one content description; use whichever reads more rows.
        val plain = rows(bank, pieces(texts.filterNot { it.startsWith("[desc] ") }), now)
        val described = rows(bank, pieces(texts.filter { it.startsWith("[desc] ") }.map { it.removePrefix("[desc] ") }), now)
        return if (described.size > plain.size) described else plain
    }

    private fun pieces(texts: List<String>): List<String> {
        val out = mutableListOf<String>()
        for (t in texts) for (p in t.split('\n')) {
            val s = p.replace(Regex("\\s+"), " ").trim()
            if (s.isNotEmpty() && s != out.lastOrNull()) out.add(s)
        }
        return out
    }

    private fun rows(bank: BankParsers.Bank, pieces: List<String>, now: Long): List<CapturedPayment> {
        val eu = bank.key in EuBankParsers.KEYS
        val tokens = pieces.map { tokenOf(it, now, eu) }
        val firstDay = tokens.indexOfFirst { it.kind == Kind.DAY }
        if (firstDay < 0) return emptyList()
        val list = tokens.drop(firstDay)

        // Is the merchant before its amount (usual) or after it?
        var before = 0
        var after = 0
        for ((i, t) in list.withIndex()) {
            if (t.kind != Kind.AMOUNT) continue
            if (list.getOrNull(i - 1)?.kind == Kind.TEXT) before++
            if (list.getOrNull(i + 1)?.kind == Kind.TEXT) after++
        }
        val textBefore = before >= after

        val out = mutableListOf<CapturedPayment>()
        val seen = HashMap<String, Int>()
        var day = 0L
        for ((i, t) in list.withIndex()) {
            if (t.kind == Kind.DAY) day = t.dayStart
            if (t.kind != Kind.AMOUNT) continue
            // The row's own texts: back to the previous amount/day, or forward to the next one.
            val segment = mutableListOf<Token>()
            if (textBefore) {
                var j = i - 1
                while (j >= 0 && list[j].kind != Kind.AMOUNT && list[j].kind != Kind.DAY) segment.add(0, list[j--])
                // A second amount of the same row (the sum in another currency) or a day total.
                if (segment.none { it.kind == Kind.TEXT }) continue
            } else {
                var j = i + 1
                while (j < list.size && list[j].kind != Kind.AMOUNT && list[j].kind != Kind.DAY) segment.add(list[j++])
                if (segment.none { it.kind == Kind.TEXT }) continue
            }
            val words = segment.filter { it.kind == Kind.TEXT }.map { it.text }
            if (words.any { FAILED_RE.containsMatchIn(it) }) continue

            val time = segment.lastOrNull { it.kind == Kind.TIME }
            val rowDay = time?.dayStart?.takeIf { it > 0 } ?: day
            val ts = when {
                time != null && time.minutes >= 0 -> rowDay + time.minutes * 60_000L
                rowDay == startOfDay(now) -> now
                else -> rowDay + 12 * 3_600_000L
            }
            if (ts > now + 60_000L) continue

            val direction = when {
                t.sign > 0 -> "income"
                t.sign < 0 -> "expense"
                words.any { INCOME_RE.containsMatchIn(it) } -> "income"
                else -> "expense"
            }
            val names = words.filter { it.length in 2..60 && !NOT_MERCHANT_RE.containsMatchIn(it) && !TIME_RE.matches(it) }
            // "Входящие переводы" above "Иван И." is the bank's category, not the payee.
            val generic = names.firstOrNull()?.let { GENERIC_RE.matches(it) } == true && names.size > 1
            val merchant = if (generic) names[1] else names.firstOrNull()
            val category = (if (generic) names[0] else names.getOrNull(1))?.takeIf { it.length <= 30 }

            // Two rows of the same amount the same day are two operations: number them, and the app
            // makes sure it has at least n+1 such operations of that day (re-reading adds nothing).
            val key = "${bank.key}|$rowDay|$direction|${t.amountMinor}"
            val n = seen.getOrDefault(key, 0)
            seen[key] = n + 1
            out.add(
                CapturedPayment(
                    source = "bill",
                    app = bank.key,
                    direction = direction,
                    amountMinor = t.amountMinor,
                    currency = t.currency,
                    merchant = merchant,
                    method = bank.name,
                    ts = ts,
                    raw = "bank_history|$n|$key",
                    category = category,
                )
            )
        }
        return out
    }

    private fun tokenOf(s: String, now: Long, eu: Boolean): Token {
        // German/Dutch apps: "-12,34 €", "€ 12,34", "- € 1.234,56", "+50,00 EUR".
        if (eu) EuBankParsers.AMOUNT_RE.matchEntire(s)?.let { m ->
            val cur = m.groupValues[2].ifEmpty { m.groupValues[5] }
            if (cur.isEmpty()) return Token(Kind.TEXT, s)
            val minor = EuBankParsers.minorOf(m.groupValues[4]) ?: return Token(Kind.TEXT, s)
            val sign = when ((m.groupValues[1] + m.groupValues[3]).trim()) { "+" -> 1; "" -> 0; else -> -1 }
            return Token(Kind.AMOUNT, s, sign = sign, amountMinor = minor, currency = EuBankParsers.currencyOf(cur))
        }
        AMOUNT_RE.matchEntire(s)?.let { m ->
            val cur = m.groupValues[5].ifEmpty { m.groupValues[2] }
            // Plain numbers ("2025", "1234") are not amounts; a sign or a currency is required.
            if (cur.isEmpty()) return Token(Kind.TEXT, s)
            val minor = BankParsers.minorOf(m.groupValues[3], m.groupValues[4]) ?: return Token(Kind.TEXT, s)
            val sign = when (m.groupValues[1]) { "+" -> 1; "" -> 0; else -> -1 }
            return Token(Kind.AMOUNT, s, sign = sign, amountMinor = minor, currency = BankParsers.currencyOf(cur))
        }
        if (s.length <= 40) {
            dayOf(s, now)?.let { dayStart ->
                val tm = TIME_RE.find(s)
                // "14 октября, 12:30" inside a row is that row's time; a bare date is a day header.
                return if (tm != null) {
                    Token(Kind.TIME, s, dayStart = dayStart, minutes = tm.groupValues[1].toInt() * 60 + tm.groupValues[2].toInt())
                } else {
                    Token(Kind.DAY, s, dayStart = dayStart)
                }
            }
        }
        TIME_RE.matchEntire(s)?.let { return Token(Kind.TIME, s, minutes = it.groupValues[1].toInt() * 60 + it.groupValues[2].toInt()) }
        return Token(Kind.TEXT, s)
    }

    private fun startOfDay(ts: Long): Long = Calendar.getInstance().apply {
        timeInMillis = ts
        set(Calendar.HOUR_OF_DAY, 0); set(Calendar.MINUTE, 0); set(Calendar.SECOND, 0); set(Calendar.MILLISECOND, 0)
    }.timeInMillis

    private fun monthOf(word: String): Int? {
        val w = word.lowercase()
        MONTHS.forEachIndexed { i, names -> if (w in names) return i + 1 }
        return null
    }

    /** Local midnight of a day header ("Сегодня", "13 октября", "Пн, 13 окт.", "13.10.2026"), or null. */
    fun dayOf(s: String, now: Long): Long? {
        val today = startOfDay(now)
        val t = s.trim()
        if (TODAY_RE.containsMatchIn(t)) return today
        if (YESTERDAY_RE.containsMatchIn(t)) return startOfDay(today - 12 * 3_600_000L)
        val cal = Calendar.getInstance().apply { timeInMillis = now }
        var d = 0
        var mo = 0
        var y = 0
        NUMERIC_DATE_RE.find(t)?.let { m ->
            d = m.groupValues[1].toInt(); mo = m.groupValues[2].toInt()
            y = m.groupValues[3].toIntOrNull()?.let { if (it < 100) 2000 + it else it } ?: 0
        } ?: DAY_MONTH_RE.find(t)?.takeIf { monthOf(it.groupValues[2]) != null }?.let { m ->
            d = m.groupValues[1].toInt(); mo = monthOf(m.groupValues[2])!!; y = m.groupValues[3].toIntOrNull() ?: 0
        } ?: MONTH_DAY_RE.find(t)?.takeIf { monthOf(it.groupValues[1]) != null }?.let { m ->
            d = m.groupValues[2].toInt(); mo = monthOf(m.groupValues[1])!!; y = m.groupValues[3].toIntOrNull() ?: 0
        } ?: return null
        if (d !in 1..31 || mo !in 1..12) return null
        fun at(year: Int) = Calendar.getInstance().apply { clear(); set(year, mo - 1, d) }.timeInMillis
        if (y != 0) return at(y)
        val thisYear = at(cal.get(Calendar.YEAR))
        // "30 декабря" seen in January is last year's.
        return if (thisYear > today) at(cal.get(Calendar.YEAR) - 1) else thisYear
    }
}
