package app.budget.budget_app.capture

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.Calendar

/** Typical texts of German/Dutch banks and Google Wallet (real samples will be added as they come). */
class EuBankParsersTest {
    private val now = Calendar.getInstance().apply { clear(); set(2026, 9, 22, 15, 30) }.timeInMillis

    private fun v(pkg: String, title: String, text: String) = BankParsers.classify(pkg, title, text, now)!!
    private fun p(pkg: String, title: String, text: String) = v(pkg, title, text).payment!!

    @Test
    fun amounts() {
        assertEquals(123456L, EuBankParsers.minorOf("1.234,56"))
        assertEquals(123456L, EuBankParsers.minorOf("1,234.56"))
        assertEquals(1250L, EuBankParsers.minorOf("12,5"))
        assertEquals(123400L, EuBankParsers.minorOf("1.234"))
        assertEquals(450L, EuBankParsers.minorOf("4,50"))
        assertNull(EuBankParsers.minorOf("0,00"))
    }

    @Test
    fun n26() {
        val r = p("de.number26.android", "N26", "Du hast 12,34 € bei REWE bezahlt.")
        assertEquals("n26", r.app)
        assertEquals("bank", r.source)
        assertEquals("expense", r.direction)
        assertEquals(1234L, r.amountMinor)
        assertEquals("EUR", r.currency)
        assertEquals("REWE", r.merchant)
        assertEquals("N26", r.method)

        val i = p("de.number26.android", "N26", "Du hast 50,00 € von Max M. erhalten.")
        assertEquals("income", i.direction)
        assertEquals(5000L, i.amountMinor)
        assertEquals("Max M", i.merchant)
    }

    @Test
    fun dkbCardPayment() {
        val r = p("de.dkb.portalapp", "Kartenzahlung", "12,34 EUR bei REWE Markt, Visa Debitkarte *1234")
        assertEquals("dkb", r.app)
        assertEquals("expense", r.direction)
        assertEquals(1234L, r.amountMinor)
        assertEquals("REWE Markt", r.merchant)
    }

    @Test
    fun sparkasseSignedWithBalance() {
        val r = p(
            "com.starfinanz.smob.android.sfinanzstatus", "Umsatz auf Ihrem Konto",
            "-1.234,56 EUR, MEDIA MARKT GMBH. Kontostand: 2.345,67 EUR",
        )
        assertEquals("sparkasse", r.app)
        assertEquals("expense", r.direction)
        assertEquals(123456L, r.amountMinor)
        assertEquals("Media Markt Gmbh", r.merchant)

        val salary = p("com.starfinanz.smob.android.sfinanzstatus", "Kontowecker", "Gutschrift: +2.100,00 EUR von ACME GmbH")
        assertEquals("income", salary.direction)
        assertEquals(210000L, salary.amountMinor)
        assertEquals("ACME GmbH", salary.merchant)
    }

    @Test
    fun ingNetherlands() {
        val out = p("com.ing.mobile", "Afschrijving", "€ 12,50 naar Albert Heijn 1234 Amsterdam")
        assertEquals("ing", out.app)
        assertEquals("expense", out.direction)
        assertEquals(1250L, out.amountMinor)
        assertEquals("Albert Heijn", out.merchant)

        val inc = p("com.ing.mobile", "Bijschrijving", "€ 50,00 van J. de Vries")
        assertEquals("income", inc.direction)
        assertEquals("J. de Vries", inc.merchant)
    }

    @Test
    fun bunqAndRevolut() {
        val b = p("com.bunq.android", "bunq", "€ 4,50 betaald aan Starbucks")
        assertEquals("bunq", b.app)
        assertEquals("expense", b.direction)
        assertEquals(450L, b.amountMinor)
        assertEquals("Starbucks", b.merchant)

        val b2 = p("com.bunq.android", "bunq", "€ 25,00 ontvangen van Anna")
        assertEquals("income", b2.direction)
        assertEquals("Anna", b2.merchant)

        val r = p("com.revolut.revolut", "Revolut", "Paid €12.50 at Lidl")
        assertEquals("revolut", r.app)
        assertEquals(1250L, r.amountMinor)
        assertEquals("Lidl", r.merchant)

        val usd = p("com.revolut.revolut", "Revolut", "Paid $8.00 at Starbucks New York")
        assertEquals("USD", usd.currency)
    }

    @Test
    fun googleWallet() {
        val w = p(EuBankParsers.GOOGLE_WALLET, "REWE", "12,34 € mit Visa •• 1234")
        assertEquals("gwallet", w.app)
        assertEquals("expense", w.direction)
        assertEquals(1234L, w.amountMinor)
        assertEquals("REWE", w.merchant)
        assertNull("a Wallet card has no account of its own", w.method)
        assertEquals("wallet", w.source)

        val nl = p(EuBankParsers.GOOGLE_WALLET, "Albert Heijn", "€ 7,80 met Mastercard ••5678")
        assertEquals(780L, nl.amountMinor)
        assertEquals("Albert Heijn", nl.merchant)
    }

    @Test
    fun skipsAdsCodesAndApprovals() {
        assertEquals("code", v("de.dkb.portalapp", "DKB", "Bitte bestätigen Sie die Zahlung von 49,99 € bei Amazon").reason)
        assertEquals("code", v("com.ing.mobile", "ING", "Keur de betaling van € 30,00 goed in de app").reason)
        assertEquals("code", v("de.ingdiba.bankingapp", "ING", "Ihre TAN für die Überweisung über 100,00 €: 123456").reason)
        assertEquals("declined", v("de.number26.android", "N26", "Zahlung über 12,34 € bei REWE abgelehnt").reason)
        assertEquals("declined", v("com.bunq.android", "bunq", "Betaling van € 5,00 geweigerd: onvoldoende saldo").reason)
        assertEquals("promo", v("com.revolut.revolut", "Revolut", "Hol dir jetzt 5 % Zinsen auf bis zu 10.000 €!").reason)
        assertEquals("promo", v("com.bunq.android", "bunq", "Nodig een vriend uit en krijg € 10 cadeau").reason)
        assertEquals("promo", v("de.dkb.portalapp", "DKB", "Jetzt Tagesgeld eröffnen und 50 € Bonus sichern").reason)
        assertEquals("no_amount", v("de.dkb.portalapp", "DKB", "Ihr Kontoauszug ist da").reason)
        // Only a TAN app: not a bank at all.
        assertNull(BankParsers.classify("com.starfinanz.mobile.android.pushtan", "S-pushTAN", "Auftrag 50,00 EUR freigeben", now))
    }

    @Test
    fun banksAreKnownByPackage() {
        assertEquals("dkb", BankParsers.bankFor("de.dkb.portalapp", "")!!.key)
        assertEquals("sparkasse", BankParsers.bankFor("com.starfinanz.smob.android.sfinanzstatus", "")!!.key)
        assertEquals("rabobank", BankParsers.bankFor("nl.rabomobiel", "")!!.key)
        assertEquals("knab", BankParsers.bankFor("nl.knab.app", "")!!.key)
        assertNull(BankParsers.bankFor("de.traderepublic.app", ""))
        // Russian banks still go through the Russian parser.
        assertEquals("sber", BankParsers.bankFor("ru.sberbankmobile", "")!!.key)
    }

    @Test
    fun historyRowsInGermanAndDutch() {
        val day = { m: Int, d: Int -> Calendar.getInstance().apply { clear(); set(2026, m - 1, d) }.timeInMillis }
        val de = listOf(
            "Umsätze", "Heute", "REWE Markt", "Kartenzahlung", "-12,34 €",
            "Gestern", "ACME GmbH", "Gutschrift", "+2.100,00 €",
            "Montag, 19. Oktober", "Lastschrift", "Stadtwerke München", "-45,00 €",
        )
        val rows = BankHistory.parse("de.dkb.portalapp", de, now)
        assertEquals(3, rows.size)
        assertEquals("REWE Markt", rows[0].merchant)
        assertEquals("expense", rows[0].direction)
        assertEquals(1234L, rows[0].amountMinor)
        assertEquals("EUR", rows[0].currency)
        assertEquals("income", rows[1].direction)
        assertEquals(210000L, rows[1].amountMinor)
        assertTrue(rows[1].ts >= day(10, 21) && rows[1].ts < day(10, 22))
        assertEquals("Stadtwerke München", rows[2].merchant)
        assertTrue(rows[2].ts >= day(10, 19) && rows[2].ts < day(10, 20))

        val nl = listOf("Vandaag", "Albert Heijn", "- € 23,45", "maandag 19 oktober", "J. de Vries", "+ € 50,00")
        val rowsNl = BankHistory.parse("com.ing.mobile", nl, now)
        assertEquals(2, rowsNl.size)
        assertEquals(2345L, rowsNl[0].amountMinor)
        assertEquals("expense", rowsNl[0].direction)
        assertEquals("income", rowsNl[1].direction)
        assertEquals("J. de Vries", rowsNl[1].merchant)
    }
}
