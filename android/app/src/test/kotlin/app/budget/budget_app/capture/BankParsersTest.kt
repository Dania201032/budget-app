package app.budget.budget_app.capture

import app.budget.budget_app.backup.BackupCrypto
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

/** Typical texts of RU/KZ banks (built from published examples; real samples will be added as they come). */
class BankParsersTest {
    private val now = 1_791_900_000_000L

    private fun p(pkg: String, title: String, text: String) = BankParsers.parse(pkg, title, text, now)

    @Test
    fun sberSms() {
        val r = p("com.google.android.apps.messaging", "900", "СЧЁТ1234 12:30 Покупка 450р Магнит Баланс: 12 345,67р")!!
        assertEquals("sber", r.app)
        assertEquals("sms", r.source)
        assertEquals("expense", r.direction)
        assertEquals(45000L, r.amountMinor)
        assertEquals("RUB", r.currency)
        assertEquals("Магнит", r.merchant)
    }

    @Test
    fun tbankPush() {
        val r = p("com.idamob.tinkoff.android", "Т-Банк", "Покупка, карта *1234. 450 ₽. Магнит. Доступно 12 345 ₽")!!
        assertEquals("tbank", r.app)
        assertEquals(45000L, r.amountMinor)
        assertEquals("Магнит", r.merchant)
    }

    @Test
    fun vtbPushWithKopecks() {
        val r = p("ru.vtb24.mobilebanking.android", "ВТБ", "Списание 1 450.50 RUB. Пятёрочка. Баланс 12345.67 RUB")!!
        assertEquals(145050L, r.amountMinor)
        assertEquals("Пятёрочка", r.merchant)
    }

    @Test
    fun incomingTransferWithName() {
        val r = p("ru.sberbankmobile", "СберБанк", "Перевод 1 000 ₽ от Иван И. Баланс: 5 000 ₽")!!
        assertEquals("income", r.direction)
        assertEquals(100000L, r.amountMinor)
        assertEquals("Иван И", r.merchant)
    }

    @Test
    fun kaspiPurchaseAndTransfer() {
        val buy = p("kz.kaspi.mobile", "Kaspi.kz", "Покупка 2 500 ₸ в MAGNUM. Доступно 120 000 ₸")!!
        assertEquals("kaspi", buy.app)
        assertEquals("KZT", buy.currency)
        assertEquals(250000L, buy.amountMinor)
        assertEquals("MAGNUM", buy.merchant)
        val tr = p("kz.kaspi.mobile", "Kaspi.kz", "Перевод 5 000 ₸ от Айгерим К.")!!
        assertEquals("income", tr.direction)
        assertEquals("Айгерим К", tr.merchant)
    }

    @Test
    fun kazakhLanguage() {
        val r = p("kz.kaspi.mobile", "Kaspi.kz", "Сатып алу 1 200 ₸ SMALL. Қолжетімді 50 000 ₸")!!
        assertEquals("expense", r.direction)
        assertEquals(120000L, r.amountMinor)
    }

    @Test
    fun salaryIsIncome() {
        val r = p("ru.alfabank.mobile.android", "Альфа-Банк", "Зачисление зарплаты 85 000,00 ₽. Баланс 90 100 ₽")!!
        assertEquals("income", r.direction)
        assertEquals(8500000L, r.amountMinor)
    }

    @Test
    fun ignored() {
        assertNull(p("ru.sberbankmobile", "СберБанк", "Код для входа: 1234. Никому не сообщайте"))
        assertNull(p("ru.sberbankmobile", "СберБанк", "Скидка 500 ₽ на первую покупку по акции"))
        assertNull(p("ru.sberbankmobile", "СберБанк", "Отказ. Покупка 450р Магнит. Недостаточно средств"))
        assertNull(p("org.telegram.messenger", "Вася", "Покупка 450р, переведи мне"))
        assertNull(p("ru.sberbankmobile", "СберБанк", "Ваш баланс 12 345 ₽"))
    }

    @Test
    fun smsFromUnknownSenderStillParsed() {
        val r = p("com.google.android.apps.messaging", "+79001234567", "Оплата 300 руб. Яндекс Такси")!!
        assertEquals("sms", r.app)
        assertEquals(30000L, r.amountMinor)
    }

    @Test
    fun backupCryptoRoundTrip() {
        val data = "{\"transactions\":[1,2,3]}".toByteArray()
        val enc = BackupCrypto.pack(data, "секрет")
        assertTrue(BackupCrypto.isEncrypted(enc))
        assertArrayEquals(data, BackupCrypto.unpack(enc, "секрет"))
        assertThrows(Exception::class.java) { BackupCrypto.unpack(enc, "wrong") }
        val plain = BackupCrypto.pack(data, null)
        assertArrayEquals(data, BackupCrypto.unpack(plain, null))

        // Automatic backups use the stored derived key; the password alone must open them.
        val salt = BackupCrypto.newSalt()
        val key = BackupCrypto.deriveKey("пароль123", salt)
        val auto = BackupCrypto.packWithKey(data, key, salt)
        assertArrayEquals(data, BackupCrypto.unpack(auto, "пароль123"))
        assertThrows(Exception::class.java) { BackupCrypto.unpack(auto, "пароль124") }
    }
}
