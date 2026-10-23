package app.budget.budget_app.capture

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.Calendar

class BankHistoryTest {
    // 2026-10-14 15:30 local time
    private val now = Calendar.getInstance().apply { clear(); set(2026, 9, 14, 15, 30) }.timeInMillis
    private fun day(m: Int, d: Int, y: Int = 2026) = Calendar.getInstance().apply { clear(); set(y, m - 1, d) }.timeInMillis
    private val vtb = "ru.vtb24.mobilebanking.android"

    @Test
    fun ads() {
        fun p(title: String, text: String) = BankParsers.classify("ru.sberbankmobile", title, text, now)!!
        assertEquals("promo", p("СберБанк", "Подключите СберПрайм всего за 1 ₽ — оплата картой в один клик").reason)
        assertEquals("promo", p("Сбер", "Кешбэк до 1 000 ₽ за оплату покупок по QR!").reason)
        assertEquals("promo", p("СберБанк", "Оплачивайте ЖКУ без комиссии, первый платёж 1 ₽").reason)
        assertEquals("promo", p("СберСпасибо", "Начислено 1 ₽ бонусами за покупки").reason)
        assertEquals("not_operation", p("СберБанк", "Ваш перевод 1 ₽ ждёт подтверждения в приложении").reason)
        assertEquals("code", p("СберБанк", "Код 4567 для оплаты 1 ₽. Никому не сообщайте").reason)
        // "транзакция" is not "акция"; "в Магните" is not an ad.
        val ok = p("СберБанк", "Покупка 450 ₽ в Магните. Транзакция одобрена")
        assertEquals("recorded", ok.reason)
        assertEquals(45000L, ok.payment!!.amountMinor)
    }

    @Test
    fun cashbackInPurchaseIsStillExpense() {
        val r = BankParsers.parse("com.idamob.tinkoff.android", "Покупка", "450 ₽, Магнит. Кешбэк 5 ₽", now)!!
        assertEquals("expense", r.direction)
        assertEquals(45000L, r.amountMinor)
    }

    @Test
    fun pushWithOperationInTitle() {
        val r = BankParsers.parse("ru.vtb24.mobilebanking.android", "Зачисление 15 000 ₽", "Счёт *1234. Баланс 20 000 ₽", now)!!
        assertEquals("income", r.direction)
        assertEquals(1500000L, r.amountMinor)
    }

    @Test
    fun brokerageIsNotABank() {
        assertNull(BankParsers.classify("ru.vtb.invest", "ВТБ Инвестиции", "Покупка 10 акций за 1 000 ₽", now))
        assertNull(BankParsers.classify("ru.tinkoff.investing", "Т-Инвестиции", "Покупка 1 000 ₽", now))
    }

    @Test
    fun historyRowsUnderDays() {
        val texts = listOf(
            "Мастер-счёт", "125 000,00 ₽", // balance before any day: not a row
            "История", "Сегодня",
            "Иван Иванович И.", "Входящий перевод", "+15 000 ₽",
            "Магнит", "Супермаркеты", "−450,50 ₽",
            "Вчера",
            "Яндекс Такси", "Транспорт", "12:40", "−320 ₽",
            "Пятёрочка", "Отклонено", "−99 ₽",
            "12 октября",
            "Магнит", "Супермаркеты", "−450,50 ₽",
            "Магнит", "Супермаркеты", "−450,50 ₽",
        )
        val rows = BankHistory.parse(vtb, texts, now)
        assertEquals(5, rows.size)
        val income = rows[0]
        assertEquals("income", income.direction)
        assertEquals(1500000L, income.amountMinor)
        assertEquals("Иван Иванович И.", income.merchant)
        assertEquals("vtb", income.app)
        assertEquals("bill", income.source)
        assertEquals(now, income.ts)
        assertEquals("expense", rows[1].direction)
        assertEquals(45050L, rows[1].amountMinor)
        assertEquals("Супермаркеты", rows[1].category)
        assertEquals(day(10, 13) + (12 * 60 + 40) * 60_000L, rows[2].ts)
        assertEquals(day(10, 12) + 12 * 3_600_000L, rows[3].ts)
        // Same amount twice the same day: numbered 0 and 1.
        assertTrue(rows[3].raw.startsWith("bank_history|0|"))
        assertTrue(rows[4].raw.startsWith("bank_history|1|"))
    }

    @Test
    fun rowsAsContentDescriptions() {
        val texts = listOf(
            "[desc] 13 октября", "[desc] Перевод от Анны\nПереводы\n+2 000 ₽", "[desc] Ozon\nМаркетплейсы\n−1 299 ₽",
        )
        val rows = BankHistory.parse(vtb, texts, now)
        assertEquals(2, rows.size)
        assertEquals("income", rows[0].direction)
        assertEquals("Ozon", rows[1].merchant)
        assertEquals(129900L, rows[1].amountMinor)
    }

    @Test
    fun unsignedAmountsUseWords() {
        val texts = listOf("Пн, 13 окт.", "Зачисление зарплаты", "50 000 ₽", "Кофе Хауз", "350 ₽")
        val rows = BankHistory.parse("ru.sberbankmobile", texts, now)
        assertEquals(listOf("income", "expense"), rows.map { it.direction })
    }

    @Test
    fun noDaysNoRows() {
        assertTrue(BankHistory.parse(vtb, listOf("Карта *1234", "12 345 ₽", "Магнит", "−450 ₽"), now).isEmpty())
    }

    @Test
    fun dayHeaders() {
        assertEquals(day(10, 14), BankHistory.dayOf("Сегодня", now))
        assertEquals(day(10, 13), BankHistory.dayOf("Вчера, 13 октября", now))
        assertEquals(day(10, 5), BankHistory.dayOf("5 октября, воскресенье", now))
        assertEquals(day(12, 30, 2025), BankHistory.dayOf("30 декабря", now))
        assertEquals(day(9, 1), BankHistory.dayOf("01.09.2026", now))
        assertEquals(day(10, 2), BankHistory.dayOf("October 2", now))
        assertNull(BankHistory.dayOf("5 маркетов", now))
        assertNull(BankHistory.dayOf("Магнит", now))
    }

    @Test
    fun sberSbpTransferFromMyself() {
        // Real push (Oct 17): money moved from my VTB to my Sber.
        val r = BankParsers.parse("ru.sberbankmobile", "Перевод по СБП от ИВАН ПЕТРОВИЧ С.", "+ 12 345 ₽ — Счёт карты VISA •• 4521", now)!!
        assertEquals("income", r.direction)
        assertEquals(1234500L, r.amountMinor)
        assertEquals("Иван Петрович С", r.merchant)
    }

    @Test
    fun ownCardIsNotAPayee() {
        val r = BankParsers.parse("ru.sberbankmobile", "Зачисление", "+ 500 ₽ — Счёт карты VISA •• 4521", now)!!
        assertNull(r.merchant)
    }

    @Test
    fun bankCategoryAbovePayee() {
        val rows = BankHistory.parse(vtb, listOf("Сегодня", "Входящие переводы", "Иван И.", "+1 000 ₽"), now)
        assertEquals("Иван И.", rows.single().merchant)
        assertEquals("Входящие переводы", rows.single().category)
    }
}
