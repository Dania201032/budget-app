package app.budget.budget_app.capture

/**
 * German and Dutch bank notifications (DKB, Sparkasse, ING, bunq, N26, Revolut, …) and Google Wallet,
 * whatever country/language is chosen in the app.
 *
 * The banks don't publish their texts and change them often, so, like [BankParsers], this is a generic
 * parser: the operation amount ("12,34 €", "€ 12,34", "-12,34 EUR", "€1,234.50"; balance amounts are
 * skipped), the direction from the sign or from words in German, Dutch and English, and the payee
 * after "bei / an / bij / aan / naar / at / to" (or "von / van / from" for money coming in). Texts it
 * is built for:
 *   N26:          "Du hast 12,34 € bei REWE bezahlt."                 "Du hast 50,00 € von Max M. erhalten."
 *   DKB:          "Kartenzahlung" | "12,34 EUR bei REWE Markt, Visa Debitkarte *1234"
 *   Sparkasse:    "Umsatz auf Ihrem Konto" | "-12,34 EUR, REWE Markt GmbH. Kontostand: 1.234,56 EUR"
 *   ING (NL):     "Afschrijving" | "€ 12,50 naar Albert Heijn 1234"   "Bijschrijving" | "€ 50,00 van J. de Vries"
 *   bunq:         "€ 4,50 betaald aan Starbucks"                     "€ 25,00 ontvangen van Anna"
 *   Revolut:      "Paid €12.50 at Lidl"
 *   Google Wallet "REWE" | "12,34 € mit Visa •• 1234"
 * Banks push ads and TAN/approval requests with amounts too, so a notification only counts when it
 * names the operation (a payment, a debit, money received…), or carries a card, a balance or a sign.
 * NOTE: not yet verified against real notifications of these banks; the Bank notifications log in the
 * app shows what was read and why something was skipped.
 */
object EuBankParsers {
    const val GOOGLE_WALLET = "com.google.android.apps.walletnfcrel"

    private val BY_PACKAGE = mapOf(
        "de.dkb.portalapp" to BankParsers.Bank("dkb", "DKB"),
        "com.starfinanz.smob.android.sfinanzstatus" to BankParsers.Bank("sparkasse", "Sparkasse"),
        "com.starfinanz.smob.android.sfinanzstatus.tablet" to BankParsers.Bank("sparkasse", "Sparkasse"),
        "de.ingdiba.bankingapp" to BankParsers.Bank("ing", "ING"),
        "com.ing.mobile" to BankParsers.Bank("ing", "ING"),
        "com.bunq.android" to BankParsers.Bank("bunq", "bunq"),
        "de.number26.android" to BankParsers.Bank("n26", "N26"),
        "com.revolut.revolut" to BankParsers.Bank("revolut", "Revolut"),
        "de.commerzbanking.mobil" to BankParsers.Bank("commerzbank", "Commerzbank"),
        "com.db.pwcc.dbmobile" to BankParsers.Bank("deutsche", "Deutsche Bank"),
        "de.comdirect.android" to BankParsers.Bank("comdirect", "comdirect"),
        "de.postbank.finanzassistent" to BankParsers.Bank("postbank", "Postbank"),
        "de.fiduciagad.android.vrbanking" to BankParsers.Bank("vr", "Volksbank"),
        "de.consorsbank" to BankParsers.Bank("consors", "Consorsbank"),
        "com.abnamro.nl.mobile.payments" to BankParsers.Bank("abnamro", "ABN AMRO"),
        "nl.rabomobiel" to BankParsers.Bank("rabobank", "Rabobank"),
        "nl.snsbank.mobielbetalen" to BankParsers.Bank("sns", "SNS"),
        "nl.asnbank.mobielbetalen" to BankParsers.Bank("asn", "ASN Bank"),
        "nl.regiobank.mobielbetalen" to BankParsers.Bank("regiobank", "RegioBank"),
        GOOGLE_WALLET to BankParsers.Bank("gwallet", "Google Wallet"),
    )

    /** Package-name fragments of other apps of these banks. */
    private val BY_PACKAGE_PART = listOf(
        "dkb" to BankParsers.Bank("dkb", "DKB"), "sparkasse" to BankParsers.Bank("sparkasse", "Sparkasse"),
        "sfinanzstatus" to BankParsers.Bank("sparkasse", "Sparkasse"), "ingdiba" to BankParsers.Bank("ing", "ING"),
        "bunq" to BankParsers.Bank("bunq", "bunq"), "number26" to BankParsers.Bank("n26", "N26"),
        "revolut" to BankParsers.Bank("revolut", "Revolut"), "commerzbank" to BankParsers.Bank("commerzbank", "Commerzbank"),
        "comdirect" to BankParsers.Bank("comdirect", "comdirect"), "postbank" to BankParsers.Bank("postbank", "Postbank"),
        "vrbanking" to BankParsers.Bank("vr", "Volksbank"), "consors" to BankParsers.Bank("consors", "Consorsbank"),
        "abnamro" to BankParsers.Bank("abnamro", "ABN AMRO"), "rabo" to BankParsers.Bank("rabobank", "Rabobank"),
        "snsbank" to BankParsers.Bank("sns", "SNS"), "asnbank" to BankParsers.Bank("asn", "ASN Bank"),
        "regiobank" to BankParsers.Bank("regiobank", "RegioBank"), "knab" to BankParsers.Bank("knab", "Knab"),
        "triodos" to BankParsers.Bank("triodos", "Triodos"), "targobank" to BankParsers.Bank("targobank", "Targobank"),
        "hypovereinsbank" to BankParsers.Bank("hvb", "HypoVereinsbank"),
    )

    /** TAN apps (S-pushTAN, DKB-TAN2go, SecureGo) and brokerage apps of the same banks. */
    private val NOT_BANK_PART = Regex("pushtan|tan2go|securego|phototan|invest|broker|trade|depot", RegexOption.IGNORE_CASE)

    val KEYS: Set<String> = (BY_PACKAGE.values + BY_PACKAGE_PART.map { it.second }).map { it.key }.toSet()

    fun bankFor(pkg: String): BankParsers.Bank? {
        BY_PACKAGE[pkg]?.let { return it }
        val lower = pkg.lowercase()
        if (!(lower.startsWith("de.") || lower.startsWith("nl.") || lower.startsWith("com.") || lower.startsWith("eu."))) return null
        if (NOT_BANK_PART.containsMatchIn(lower)) return null
        return BY_PACKAGE_PART.firstOrNull { lower.contains(it.first) }?.second
    }

    private const val L = "a-zäöüßéëïóèàç"
    private const val CUR = "€|EUR|\\$|USD|£|GBP|CHF|PLN|zł|CZK|Kč|SEK|DKK|NOK|HUF|Ft|CNY|¥|RUB|₽|TRY|₺"
    private const val NUM = "\\d{1,3}(?:[.,\\u00A0\\u202F' ]\\d{3})+(?:[.,]\\d{1,2})?|\\d+(?:[.,]\\d{1,2})?"

    /** sign, currency before, sign, number, currency after. */
    val AMOUNT_RE = Regex(
        "(?<![\\d$L.,])([+\\-−–]\\s?)?(?:($CUR)\\s?)?([+\\-−–]\\s?)?($NUM)(?:\\s?($CUR))?(?![\\d$L])",
        RegexOption.IGNORE_CASE,
    )

    private const val BALANCE_WORDS =
        "kontostand|saldo|verfügbar|verfuegbar|guthaben|neuer stand|limit|beschikbaar|balance|available|disponible"
    private val BALANCE_CONTEXT = Regex("($BALANCE_WORDS)[^\\d]{0,15}$", RegexOption.IGNORE_CASE)
    private val BALANCE_ANYWHERE = Regex("($BALANCE_WORDS)[^\\d]{0,15}\\d", RegexOption.IGNORE_CASE)

    /** TANs, approval requests ("Bitte bestätigen Sie die Zahlung …"), log-ins: not operations yet. */
    private val CODE_RE = Regex(
        "(?<![$L])(tan|pushtan|code|passwort|password|wachtwoord|verificatie\\w*|bestätigen|bestaetigen|" +
            "freigabe|freigeben|goedkeuren|keur .{0,40} goed|bevestigen|anmeld\\w*|inlog\\w*|log ?in|" +
            "approve|3-?d ?secure|identcheck)(?![$L])",
        RegexOption.IGNORE_CASE,
    )
    private val DECLINED_RE = Regex(
        "abgelehnt|fehlgeschlagen|nicht (ausgeführt|durchgeführt|möglich)|storniert|deckung|geweigerd|mislukt|" +
            "afgewezen|niet gelukt|onvoldoende|geannuleerd|declined|failed|insufficient|rejected|cancel+ed",
        RegexOption.IGNORE_CASE,
    )

    /** Words only ads use. */
    private val AD_RE = Regex(
        "gewinnspiel|gutschein|rabatt|geschenk|cadeau|nodig .{0,30} uit|prämie|praemie|aanbieding|korting|winactie|promo|newsletter|empfehl|" +
            "freunde werben|vriend uitnodig|invite|refer a friend",
        RegexOption.IGNORE_CASE,
    )

    /** Looks like an ad: trusted only with a card, a balance or a signed amount. */
    private val PROMO_RE = Regex(
        "[!?]|\\d\\s?%|(?<![$L])(jetzt|entdecke\\w*|sichere?n?|teste\\w*|neu|aktion|angebot\\w*|bis zu|" +
            "nu|ontdek\\w*|probeer|profiteer|actie|tot wel|nieuw|now|discover|try|offer|up to|cashback|zinsen? bis)(?![$L])",
        RegexOption.IGNORE_CASE,
    )

    private val INCOME_RE = Regex(
        "(?<![$L])(gutschrift|geldeingang|zahlungseingang|eingang|eingegangen|gutgeschrieben|erhalten|empfangen|" +
            "rückerstattung|rueckerstattung|erstattung|erstattet|rückbuchung|gehalt|lohn|zinsgutschrift|" +
            "bijgeschreven|bijschrijving|ontvangen|terugbetaling|terugbetaald|teruggestort|storting|salaris|" +
            "received|refund\\w*|credited|incoming|deposit\\w*|salary|you got|aufgeladen|opgewaardeerd|top-?up)(?![$L])",
        RegexOption.IGNORE_CASE,
    )
    private val EXPENSE_RE = Regex(
        "(?<![$L])(kartenzahlung|kartenumsatz|zahlung|bezahlt|gezahlt|ausgegeben|abgebucht|abbuchung|belastet|" +
            "belastung|lastschrift|abhebung|bargeldabhebung|gesendet|betaald|betaling|pinbetaling|afgeschreven|" +
            "afschrijving|incasso|opname|geldopname|uitgegeven|verstuurd|paid|spent|payment|purchase|debited|" +
            "withdrawal|direct debit|sent)(?![$L])",
        RegexOption.IGNORE_CASE,
    )

    /** Words that make the notification an operation (besides the two lists above). */
    private val OPERATION_RE = Regex(
        "(?<![$L])(umsatz|überweisung|ueberweisung|dauerauftrag|overboeking|transactie|transaction|transfer)(?![$L])",
        RegexOption.IGNORE_CASE,
    )

    /** A masked card number: proves an operation (an ad doesn't name your card). */
    private const val CARD_MASK =
        "[*•·x]{1,4}\\s?\\d{4}(?!\\d)|(karte|card|kaart|pas)\\s*(endet auf|eindigend op|ending in)?\\s*[*•·]*\\s?\\d{4}(?!\\d)"
    private val CARD_MASK_RE = Regex(CARD_MASK, RegexOption.IGNORE_CASE)

    /** Card words removed from a payee ("REWE, Visa Debitkarte *1234"). */
    private val CARD_RE = Regex(
        "$CARD_MASK|(?<![$L])(visa|mastercard|maestro|girocard|debitkarte|kreditkarte|debit card|credit card)(?![$L])",
        RegexOption.IGNORE_CASE,
    )

    /** The word before the payee: "bei REWE", "aan Albert Heijn"; "von / van / from" for money coming in. */
    private val TO_RE = Regex("(?<![$L])(bei|an|bij|aan|naar|at|to|für|voor)\\s+(?=\\S)", RegexOption.IGNORE_CASE)
    private val FROM_RE = Regex("(?<![$L])(von|van|from)\\s+(?=\\S)", RegexOption.IGNORE_CASE)

    // A dot ends the payee, except after an initial ("J. de Vries", "Max M."); so does a number ("Albert Heijn 1234").
    private val MERCHANT_STOP = Regex(
        "((?<![\\s.]\\p{L})(?<!^\\p{L})\\.(\\s|$)|[,;|\\n(]|\\s[+\\-−–]?\\d|" +
            "\\s(in höhe|ter waarde|über|ueber|mit|met|with|via|am|op|on|um|om|bezahlt|gezahlt|betaald|paid|erhalten|ontvangen|" +
            "abgebucht|afgeschreven|bijgeschreven|ausgegeben|gesendet|verstuurd)(?![$L])|\\s[+\\-−–]?\\s?(€|eur)\\s?\\d|" +
            "$BALANCE_WORDS|$)",
        RegexOption.IGNORE_CASE,
    )

    /** Titles that are not a payee: the bank, the app, the operation type. */
    private val GENERIC_TITLE = Regex(
        "^(google( wallet| pay)?|wallet|dkb|sparkasse|ing|bunq|n26|revolut|commerzbank|deutsche bank|comdirect|" +
            "postbank|volksbank|consorsbank|abn ?amro|rabobank|sns|asn|regiobank|knab|triodos|" +
            "neue? \\w+|nieuwe? \\w+|new \\w+|kontowecker|umsatz\\w*|.*(zahlung|betaling|schrijving|buchung|transactie|" +
            "transaction|payment|überweisung|overboeking|lastschrift|incasso|gutschrift|eingang|ontvangen|erhalten|" +
            "abbuchung|abhebung|opname)\\b.*)$",
        RegexOption.IGNORE_CASE,
    )

    fun currencyOf(s: String): String = when (s.lowercase()) {
        "€", "eur" -> "EUR"
        "$", "usd" -> "USD"
        "£", "gbp" -> "GBP"
        "chf" -> "CHF"
        "pln", "zł" -> "PLN"
        "czk", "kč" -> "CZK"
        "sek" -> "SEK"
        "dkk" -> "DKK"
        "nok" -> "NOK"
        "huf", "ft" -> "HUF"
        "cny", "¥" -> "CNY"
        "rub", "₽" -> "RUB"
        "try", "₺" -> "TRY"
        else -> "EUR"
    }

    /**
     * "1.234,56" / "1,234.56" / "12,5" / "1 234" -> minor units; null for zero. The last separator
     * followed by one or two digits is the decimal one, the others group thousands.
     */
    fun minorOf(number: String): Long? {
        val s = number.replace(Regex("[\\s\\u00A0\\u202F']"), "")
        val last = s.indexOfLast { it == '.' || it == ',' }
        val (whole, cents) = if (last >= 0 && s.length - last - 1 in 1..2) {
            s.substring(0, last) to s.substring(last + 1)
        } else {
            s to ""
        }
        val w = whole.replace(".", "").replace(",", "")
        if (w.isEmpty() && cents.isEmpty()) return null
        return "${w.ifEmpty { "0" }}.${cents.padEnd(2, '0')}".toBigDecimalOrNull()?.movePointRight(2)?.toLong()?.takeIf { it > 0 }
    }

    fun classify(bank: BankParsers.Bank, title: String, text: String, now: Long): BankParsers.Verdict {
        fun clean(s: String) = s.replace('\n', ' ').replace(Regex("\\s+"), " ").trim()
        val head = clean(title)
        val main = clean(text)
        val body = listOf(head, main).filter { it.isNotEmpty() }.joinToString(". ")
        if (body.isEmpty()) return BankParsers.Verdict(null, "no_amount")
        when {
            CODE_RE.containsMatchIn(body) -> return BankParsers.Verdict(null, "code")
            DECLINED_RE.containsMatchIn(body) -> return BankParsers.Verdict(null, "declined")
            AD_RE.containsMatchIn(body) -> return BankParsers.Verdict(null, "promo")
        }

        // An amount needs a currency; amounts right after "Kontostand/Saldo" are the balance.
        val m = AMOUNT_RE.findAll(body).firstOrNull {
            (it.groupValues[2].isNotEmpty() || it.groupValues[5].isNotEmpty()) &&
                !BALANCE_CONTEXT.containsMatchIn(body.substring(0, it.range.first))
        } ?: return BankParsers.Verdict(null, "no_amount")
        val amount = minorOf(m.groupValues[4]) ?: return BankParsers.Verdict(null, "no_amount")
        val sign = (m.groupValues[1] + m.groupValues[3]).trim()
        val wallet = bank.key == "gwallet"

        val income = INCOME_RE.containsMatchIn(body)
        val expense = EXPENSE_RE.containsMatchIn(body)
        val operation = income || expense || OPERATION_RE.containsMatchIn(body)
        val hard = wallet || sign.isNotEmpty() || CARD_MASK_RE.containsMatchIn(body) || BALANCE_ANYWHERE.containsMatchIn(body)
        val promo = PROMO_RE.containsMatchIn(body)
        if (!hard && (promo || !operation)) return BankParsers.Verdict(null, if (promo) "promo" else "not_operation")

        val from = FROM_RE.find(body)
        val direction = when {
            sign == "+" -> "income"
            sign.isNotEmpty() -> "expense"
            wallet -> if (income) "income" else "expense"
            income -> "income"
            expense -> "expense"
            // "Überweisung / Overboeking / Transfer": from someone is money coming in.
            from != null && TO_RE.find(body)?.let { it.range.first > from.range.first } != false -> "income"
            operation || hard -> "expense"
            else -> return BankParsers.Verdict(null, "not_operation")
        }
        val payment = CapturedPayment(
            // A Wallet payment is a card payment of some bank: kept apart until that bank's own push or history row.
            source = if (wallet) "wallet" else "bank",
            app = bank.key,
            direction = direction,
            amountMinor = amount,
            currency = currencyOf(m.groupValues[2].ifEmpty { m.groupValues[5] }),
            merchant = merchantOf(head, main, body, m.range, direction, wallet),
            // A Google Wallet card may be of any bank: no account of its own (the bank's push, if any, adds it).
            method = if (wallet) null else bank.name,
            ts = now,
            raw = "$title | $text".take(500),
        )
        return BankParsers.Verdict(payment, "recorded")
    }

    private fun merchantOf(head: String, main: String, body: String, amount: IntRange, direction: String, wallet: Boolean): String? {
        // Google Wallet: the title is the shop.
        if (wallet && head.isNotEmpty() && !GENERIC_TITLE.matches(head) && AMOUNT_RE.find(head) == null) return tidy(head)
        val re = if (direction == "income") FROM_RE else TO_RE
        // The preposition nearest after the amount ("12,34 € bei REWE"), else any ("Du hast bei REWE 12,34 € bezahlt").
        val found = re.findAll(body).sortedBy { if (it.range.first >= amount.last) 0 else 1 }
            .mapNotNull { m -> cut(body.substring(m.range.last + 1)) }.firstOrNull()
        if (found != null) return found
        // "-12,34 EUR, REWE Markt GmbH. Kontostand …"
        cut(body.substring(amount.last + 1).trimStart(' ', '.', ',', ':', ';', '-', '—'))?.let { return it }
        // A title that is neither the bank nor the operation is the payee ("Lidl" | "Paid €12.50").
        if (head.isNotEmpty() && !GENERIC_TITLE.matches(head) && AMOUNT_RE.find(head) == null) return tidy(head)
        return null
    }

    private fun cut(s: String): String? {
        val stop = MERCHANT_STOP.find(s)?.range?.first ?: s.length
        val m = s.substring(0, stop).replace(CARD_RE, "").trim(' ', '.', ',', ';', ':', '-', '—', '"', '„', '“', '\'')
        if (m.length < 2 || m.all { it.isDigit() || it.isWhitespace() }) return null
        if (GENERIC_TITLE.matches(m) || OWN_RE.matches(m)) return null
        return tidy(m)
    }

    /** My own account or card, not a payee. */
    private val OWN_RE = Regex(
        "(ihr(em)?|uw|je|your|mein(em)?|mijn)?\\s*(konto|girokonto|tagesgeld\\w*|rekening|betaalrekening|spaarrekening|account|karte|kaart|card)",
        RegexOption.IGNORE_CASE,
    )

    /** "MEDIA MARKT GMBH" -> "Media Markt Gmbh"; a one-word brand ("REWE", "LIDL") stays as it is. */
    private fun tidy(s: String): String {
        val t = s.trim().take(40).trim()
        return if (' ' in t) BankParsers.prettyName(t) else t
    }
}
