package app.budget.budget_app.capture

/**
 * Russian and Kazakh bank notifications (app pushes and SMS), independent of the app's country/language;
 * German and Dutch banks and Google Wallet are read by [EuBankParsers].
 *
 * Formats differ between banks and change often, so this is a generic parser: it finds the operation
 * amount (skipping "Баланс/Доступно/Остаток" amounts), the direction from keywords and the merchant
 * from the text around the amount. Typical texts it is built for:
 *   Сбер:    "Покупка 450р Магнит Баланс: 12 345,67р"           (SMS from 900 or push)
 *   Т-Банк:  "Покупка, карта *1234. 450 ₽. Магнит. Доступно 12 345 ₽"
 *   ВТБ:     "Списание 450.00 RUB. Магнит. Баланс 12345.67 RUB"
 *   Kaspi:   "Покупка 2 500 ₸ в MAGNUM. Доступно 120 000 ₸"
 *   Kaspi:   "Перевод 5 000 ₸ от Айгерим К."
 * Banks also push ads with amounts ("СберПрайм за 1 ₽"), so a notification only counts when it looks
 * like an operation: a card/account or a balance is named, or it starts with the operation itself.
 * NOTE: not yet verified against real notifications of every bank.
 */
object BankParsers {
    data class Bank(val key: String, val name: String)

    private val BY_PACKAGE = mapOf(
        "ru.sberbankmobile" to Bank("sber", "Сбер"),
        "ru.vtb24.mobilebanking.android" to Bank("vtb", "ВТБ"),
        "com.idamob.tinkoff.android" to Bank("tbank", "Т-Банк"),
        "ru.alfabank.mobile.android" to Bank("alfa", "Альфа-Банк"),
        "ru.alfabank.mobile.android.huawei" to Bank("alfa", "Альфа-Банк"),
        "ru.gazprombank.android.mobilebank.app" to Bank("gpb", "Газпромбанк"),
        "ru.ozon.fintech.finance" to Bank("ozon", "Ozon Банк"),
        "ru.yoo.money" to Bank("yoomoney", "ЮMoney"),
        "kz.kaspi.mobile" to Bank("kaspi", "Kaspi"),
    )

    /** Package-name fragments of other RU/KZ bank apps. */
    private val BY_PACKAGE_PART = listOf(
        "sber" to Bank("sber", "Сбер"), "vtb" to Bank("vtb", "ВТБ"), "tinkoff" to Bank("tbank", "Т-Банк"),
        "tbank" to Bank("tbank", "Т-Банк"), "alfa" to Bank("alfa", "Альфа-Банк"), "tochka" to Bank("tochka", "Точка"),
        "gazprombank" to Bank("gpb", "Газпромбанк"), "raiffeisen" to Bank("raif", "Райффайзен"),
        "psbank" to Bank("psb", "ПСБ"), "rshb" to Bank("rshb", "Россельхозбанк"), "pochta" to Bank("pochta", "Почта Банк"),
        "sovcom" to Bank("sovcom", "Совкомбанк"), "otkritie" to Bank("otkritie", "Открытие"),
        "mtsbank" to Bank("mts", "МТС Банк"), "uralsib" to Bank("uralsib", "Уралсиб"),
        "kaspi" to Bank("kaspi", "Kaspi"), "halyk" to Bank("halyk", "Halyk"), "jusan" to Bank("jusan", "Jusan"),
        "forte" to Bank("forte", "ForteBank"), "bcc" to Bank("bcc", "БЦК"), "freedom" to Bank("freedom", "Freedom"),
        "homecredit" to Bank("homecredit", "Home Credit"), "eubank" to Bank("eurasian", "Евразийский"),
    )

    /** Brokerage apps of the same banks ("ru.vtb.invest", "ru.tinkoff.investing"): trades are not spending. */
    private val NOT_BANK_PART = Regex("invest|broker|trade", RegexOption.IGNORE_CASE)

    val SMS_APPS = setOf(
        "com.google.android.apps.messaging", "com.android.mms", "com.android.messaging",
        "com.samsung.android.messaging", "com.nothing.messaging", "com.miui.mms", "com.oneplus.mms",
    )

    /** SMS sender -> bank. */
    private val BY_SENDER = listOf(
        Regex("^900$|sber|сбер", RegexOption.IGNORE_CASE) to Bank("sber", "Сбер"),
        Regex("vtb|втб", RegexOption.IGNORE_CASE) to Bank("vtb", "ВТБ"),
        Regex("tinkoff|t-bank|tbank|т-банк", RegexOption.IGNORE_CASE) to Bank("tbank", "Т-Банк"),
        Regex("alfa|альфа", RegexOption.IGNORE_CASE) to Bank("alfa", "Альфа-Банк"),
        Regex("tochka|точка", RegexOption.IGNORE_CASE) to Bank("tochka", "Точка"),
        Regex("kaspi", RegexOption.IGNORE_CASE) to Bank("kaspi", "Kaspi"),
        Regex("halyk", RegexOption.IGNORE_CASE) to Bank("halyk", "Halyk"),
        Regex("jusan", RegexOption.IGNORE_CASE) to Bank("jusan", "Jusan"),
    )

    fun bankFor(pkg: String, title: String): Bank? {
        BY_PACKAGE[pkg]?.let { return it }
        EuBankParsers.bankFor(pkg)?.let { return it }
        if (pkg in SMS_APPS) {
            return BY_SENDER.firstOrNull { it.first.containsMatchIn(title.trim()) }?.second ?: Bank("sms", "SMS")
        }
        val lower = pkg.lowercase()
        if (!(lower.startsWith("ru.") || lower.startsWith("kz.") || lower.startsWith("com."))) return null
        if (NOT_BANK_PART.containsMatchIn(lower)) return null
        return BY_PACKAGE_PART.firstOrNull { lower.contains(it.first) }?.second
    }

    // Amount followed by a currency: "450р", "12 345,67 ₽", "2 500 ₸", "450.00 RUB", "$12.50" is handled below.
    private val AMOUNT_RE = Regex(
        "(?<![\\d.,])(\\d{1,3}(?:[  \\u202F]\\d{3})+|\\d+)(?:[.,](\\d{1,2}))?\\s?" +
            "(₽|рубл[а-яё]*|руб\\.?|р\\.?|RUB|RUR|₸|тг\\.?|тенге|KZT|USD|\\$|EUR|€|CNY|¥)(?![a-zа-яё])",
        RegexOption.IGNORE_CASE,
    )
    private const val BALANCE_WORDS = "баланс|доступно|остаток|бал\\.|лимит|қолжетімді|қалдық|balance|available"
    private val BALANCE_CONTEXT = Regex("($BALANCE_WORDS)[^\\d]{0,12}$", RegexOption.IGNORE_CASE)
    private val BALANCE_ANYWHERE = Regex("($BALANCE_WORDS)[^\\d]{0,12}\\d", RegexOption.IGNORE_CASE)

    private val CODE_RE = Regex("(?<![а-яёa-z])(код|code|пароль|password)(?![а-яёa-z])|не сообщайте", RegexOption.IGNORE_CASE)
    private val DECLINED_RE = Regex("отклон|недостаточно|отказ|declined|failed|не выполн|заблокир", RegexOption.IGNORE_CASE)

    /** Words only ads use. ("акци" must start a word: "транзакция" is fine.) */
    private val AD_RE = Regex(
        "(?<![а-яё])(акци|скидк|выгод|промокод|розыгрыш|предлага|предложени|подарок|подарк|приз[ауо ])",
        RegexOption.IGNORE_CASE,
    )

    /** Looks like an ad ("Подключите … всего за 1 ₽!", "кешбэк до 5 000 ₽"): trusted only with a card or a balance. */
    private val PROMO_RE = Regex(
        "(?<![а-яё])(получите|получайте|оформите|подключите|попробуйте|успейте|узнайте|переходите|участвуйте|" +
            "воспользуйтесь|пользуйтесь|откройте|закажите|купите|покупайте|оплатите|оплачивайте|платите|переведите|" +
            "пополните|выберите|активируйте|заберите|забирайте|копите|экономьте|скачайте|обновите|заходите|" +
            "приглашайте|присоединяйтесь|проверьте|смотрите|ловите|возвращайте)(?![а-яё])|" +
            "[!?]|(?<![а-яё])(от|до|всего за)\\s+\\d|\\d\\s?%|" +
            "(?<![а-яё])(бесплатн|подписк|специальн|персональн|балл|бонус|спасибо|кредит|ипотек|вклад|ставк|страхов|" +
            "инвест|оформ|подключ)",
        RegexOption.IGNORE_CASE,
    )

    /** The operation named at the start of the title or the text: "Покупка 450р…", title "Зачисление". */
    private val OPERATION_START_RE = Regex(
        "^\\W{0,3}(покупка|оплата|списание|зачисление|поступление|пополнение|перевод|входящий перевод|" +
            "исходящий перевод|снятие|выдача наличных|возврат|отмена покупки|платёж|платеж|зарплата|" +
            "сатып алу|төлем|аударым|purchase|payment|transfer|refund|withdrawal|top-up)(?![а-яёa-z])",
        RegexOption.IGNORE_CASE,
    )

    private val INCOME_OPERATIONS = Regex("^(зачисление|поступление|пополнение|входящий|возврат|отмена|зарплата|refund|top-up)")

    private val INCOME_RE = Regex(
        "зачислен|поступлен|пополнен|получен|возврат|входящ|кешб[эе]к|cashback|зарплат|" +
            "перевод[^.]{0,40}\\sот\\s|аударым келді|түсті|толықтыр|refund|received|credited|top[- ]?up|salary|" +
            "(?<![\\d\\w])\\+\\s?\\d",
        RegexOption.IGNORE_CASE,
    )
    private val EXPENSE_RE = Regex(
        "покупк|оплат|списан|снятие|выдача|перевод|плат[её]ж|сатып алу|төлем|аударым|шешу|" +
            "purchase|payment|paid|debited|withdrawal|transfer",
        RegexOption.IGNORE_CASE,
    )
    private val CARD_RE = Regex("(карта|card|счёт|счет|сч)\\s*[*•.]?\\s*\\d{4}|[*•]{1,2}\\s?\\d{4}|MIR-?\\d{4}|VISA\\d{4}|ECMC\\d{4}", RegexOption.IGNORE_CASE)
    private val MERCHANT_STOP = Regex("(\\.\\s|баланс|доступно|остаток|қолжетімді|комисси|balance|available|$)", RegexOption.IGNORE_CASE)

    fun currencyOf(s: String): String {
        val c = s.lowercase().trimEnd('.')
        return when {
            c == "₽" || c == "р" || c.startsWith("руб") || c == "rub" || c == "rur" -> "RUB"
            c == "₸" || c == "тг" || c == "тенге" || c == "kzt" -> "KZT"
            c == "$" || c == "usd" -> "USD"
            c == "€" || c == "eur" -> "EUR"
            c == "¥" || c == "cny" -> "CNY"
            else -> "RUB"
        }
    }

    /** One bank notification: the operation, or why it was not taken ("code", "declined", "promo", …). */
    data class Verdict(val payment: CapturedPayment?, val reason: String)

    fun parse(pkg: String, title: String, text: String, now: Long): CapturedPayment? =
        classify(pkg, title, text, now)?.payment

    /** null = not a bank's notification at all. */
    fun classify(pkg: String, title: String, text: String, now: Long): Verdict? {
        val bank = bankFor(pkg, title) ?: return null
        // German and Dutch banks write amounts and operations their own way.
        if (bank.key in EuBankParsers.KEYS && pkg !in SMS_APPS) return EuBankParsers.classify(bank, title, text, now)
        val sms = bank.key == "sms" || pkg in SMS_APPS
        fun clean(s: String) = s.replace('\n', ' ').replace(Regex("\\s+"), " ").trim()
        // A push may carry the operation in its title ("Списание 450 ₽"); an SMS title is only the sender.
        val head = if (sms) "" else clean(title)
        val main = clean(text)
        if (main.isEmpty()) return Verdict(null, "no_amount")
        val body = listOf(head, main).filter { it.isNotEmpty() }.joinToString(". ")
        when {
            CODE_RE.containsMatchIn(body) -> return Verdict(null, "code")
            DECLINED_RE.containsMatchIn(body) -> return Verdict(null, "declined")
            AD_RE.containsMatchIn(body) -> return Verdict(null, "promo")
        }

        val m = AMOUNT_RE.findAll(body).firstOrNull { !BALANCE_CONTEXT.containsMatchIn(body.substring(0, it.range.first)) }
            ?: return Verdict(null, "no_amount")
        val amount = minorOf(m.groupValues[1], m.groupValues[2]) ?: return Verdict(null, "no_amount")

        // Ads mention payments and amounts too; for them only a card or a balance proves an operation.
        val hard = CARD_RE.containsMatchIn(body) || BALANCE_ANYWHERE.containsMatchIn(body)
        val operation = (OPERATION_START_RE.find(head) ?: OPERATION_START_RE.find(main))?.groupValues?.get(1)?.lowercase()
        val promo = PROMO_RE.containsMatchIn(body)
        if (!hard && (promo || operation == null)) return Verdict(null, if (promo) "promo" else "not_operation")

        // The operation word decides ("Покупка … Кешбэк 5 ₽" is still a purchase); otherwise keywords anywhere.
        val direction = when {
            operation != null && INCOME_OPERATIONS.containsMatchIn(operation) -> "income"
            operation != null && !operation.startsWith("перевод") && !operation.startsWith("transfer") &&
                operation != "аударым" -> "expense"
            INCOME_RE.containsMatchIn(body) -> "income"
            EXPENSE_RE.containsMatchIn(body) -> "expense"
            else -> return Verdict(null, "not_operation")
        }
        val payment = CapturedPayment(
            source = if (sms) "sms" else "bank",
            app = bank.key,
            direction = direction,
            amountMinor = amount,
            currency = currencyOf(m.groupValues[3]),
            merchant = merchantAfter(body, m.range.last + 1, direction),
            method = bank.name,
            ts = now,
            raw = "$title | $text".take(500),
        )
        return Verdict(payment, "recorded")
    }

    /** "12 345", "67" -> 1234567; null for zero. */
    fun minorOf(whole: String, cents: String): Long? {
        val w = whole.replace(Regex("[\\s  \\u202F]"), "")
        val c = cents.padEnd(2, '0').ifEmpty { "00" }
        return "$w.$c".toBigDecimalOrNull()?.movePointRight(2)?.toLong()?.takeIf { it > 0 }
    }

    private fun merchantAfter(body: String, from: Int, direction: String): String? {
        // "Перевод 5 000 ₸ от Айгерим К." / "Перевод от Иван И. 1000р"
        // Sber: title "Перевод по СБП от ИВАН ПЕТРОВИЧ С." + ". " — the initial's dot doubles.
        if (direction == "income") {
            FROM_RE.find(body)?.let { m -> return prettyName(m.groupValues[1].trim()).ifEmpty { null } }
        }
        var rest = body.substring(from).trimStart(' ', '.', ',', ':', ';', '-', '—')
        rest = rest.replaceFirst(Regex("^(в|во|at|in|на)\\s+", RegexOption.IGNORE_CASE), "")
        val stop = MERCHANT_STOP.find(rest)?.range?.first ?: rest.length
        var merchant = rest.substring(0, stop).replace(CARD_RE, "").trim(' ', '.', ',', ';', ':', '-', '—')
        if (merchant.length > 40) merchant = merchant.take(40).trim()
        // "Счёт карты VISA •• 4521" is my own card, not a payee.
        if (OWN_ACCOUNT_RE.matches(merchant)) return null
        return merchant.takeIf { it.length >= 2 && !it.all { c -> c.isDigit() || c.isWhitespace() } }
    }

    private val FROM_RE = Regex(
        "\\sот\\s+([^.,;|]{2,40}?)(?:\\.+\\s|\\.+$|,|;|\\s+\\||\\s+баланс|\\s+доступно|$)",
        RegexOption.IGNORE_CASE,
    )
    private val OWN_ACCOUNT_RE = Regex(
        "(сч[её]т|карта|счёт карты|сч[её]т карты|card|account|кошел[её]к)(\\s+(visa|mir|мир|mastercard|ecmc|unionpay))?",
        RegexOption.IGNORE_CASE,
    )

    /** "ИВАН ПЕТРОВИЧ С" -> "Иван Петрович С" (banks often write names in capitals). */
    fun prettyName(s: String): String {
        if (s.any { it.isLowerCase() }) return s
        return s.split(' ').joinToString(" ") { w ->
            if (w.length <= 2) w else w.take(1) + w.drop(1).lowercase()
        }
    }
}
