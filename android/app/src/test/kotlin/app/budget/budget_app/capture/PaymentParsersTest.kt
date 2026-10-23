package app.budget.budget_app.capture

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test

/** Texts below are real accessibility/notification captures from Alipay (Oct 12, 2026). */
class PaymentParsersTest {
    private val alipay = "com.eg.android.AlipayGphone"
    private val msp = "com.alipay.android.msp.ui.views.MspContainerActivity"
    private val now = 1_791_806_658_010L

    private val cashierTexts = listOf(
        "[desc] Close", "全家便利店", "[desc] Payment amount: 50.00 yuan", "[desc] Account,137******39",
        "Account", "137******39", "[desc] Selected,Balance,Description of payment channel content: Payment toolschannel",
        "Balance", "Payment tools", "[desc] View all", "[desc] 密码共6位，已输入0位", "137******39",
        "1", "2", "3", "4", "5", "6", "7", "8", "9", "0", "[desc] 删除",
    )

    private val successTexts = listOf(
        "[desc] Payment Successful￥50.00", "Payment Successful", "50.00", "全家便利店", "￥50.00",
        "Payment method", "Balance", "Done", "[desc] Home", "Home",
    )

    @Test
    fun alipaySuccessScreen() {
        val p = PaymentParsers.parseSuccessScreen(alipay, msp, successTexts, now, null)
        assertNotNull(p)
        p!!
        assertEquals("alipay", p.app)
        assertEquals("expense", p.direction)
        assertEquals(5000L, p.amountMinor)
        assertEquals("全家便利店", p.merchant)
        assertEquals("Balance", p.method)
        assertEquals("screen", p.source)
    }

    @Test
    fun cashierScreenIsNotAPayment() {
        assertNull(PaymentParsers.parseSuccessScreen(alipay, msp, cashierTexts, now, null))
        val c = PaymentParsers.parseCashier(cashierTexts, now)
        assertEquals("全家便利店", c?.merchant)
        assertEquals(5000L, c?.amountMinor)
    }

    @Test
    fun merchantFallsBackToCashier() {
        val noMerchant = listOf("Payment Successful", "￥50.00", "Payment method", "Balance", "Done")
        val cashier = PaymentParsers.parseCashier(cashierTexts, now - 4000)
        val p = PaymentParsers.parseSuccessScreen(alipay, msp, noMerchant, now, cashier)
        assertEquals("全家便利店", p?.merchant)
    }

    @Test
    fun chineseSuccessScreen() {
        val texts = listOf("支付成功", "￥1,234.50", "全家便利店", "付款方式", "余额宝", "完成")
        val p = PaymentParsers.parseSuccessScreen(alipay, msp, texts, now, null)
        assertEquals(123450L, p?.amountMinor)
        assertEquals("全家便利店", p?.merchant)
        assertEquals("余额宝", p?.method)
    }

    @Test
    fun wechatChatsAreIgnored() {
        val texts = listOf("张三", "支付成功 ¥20.00", "好的")
        assertNull(PaymentParsers.parseSuccessScreen("com.tencent.mm", "com.tencent.mm.ui.LauncherUI", texts, now, null))
    }

    @Test
    fun alipayExpenseNotification() {
        val p = PaymentParsers.parseNotification(alipay, "交易提醒", "你有一笔50.00元的支出，点击领取12个支付宝积分。", now)
        assertEquals("expense", p?.direction)
        assertEquals(5000L, p?.amountMinor)
        assertEquals("notification", p?.source)
    }

    @Test
    fun alipayIncomeNotification() {
        val p = PaymentParsers.parseNotification(alipay, "交易提醒", "你有一笔100.00元的收入，点此查看详情。", now)
        assertEquals("income", p?.direction)
        assertEquals(10000L, p?.amountMinor)
    }

    @Test
    fun unrelatedNotificationsAreIgnored() {
        assertNull(PaymentParsers.parseNotification(alipay, "蚂蚁森林", "你收到了能量", now))
        assertNull(PaymentParsers.parseNotification("com.tencent.mm", "张三", "晚上吃饭花了¥50", now))
    }

    @Test
    fun paymentCodeCardOverPayReceivePage() {
        // Real capture, Oct 13: success card drawn over Alipay's "Pay / Receive" page.
        val texts = listOf(
            "[desc] Return Button", "", "[desc] Return Button", "Pay / Receive", "[desc] more Button", "",
            "General Member", "", "Paying...", "[desc] Barcode", "Tap to view payment code",
            "[desc] Balance Default payment method Button", "Balance", "Default payment method", "",
            "[desc] Receive Button", "Receive", "", "[desc] Alipay Tap Button", "Alipay Tap", "做任务领0.20元红包", "",
            "[desc] Transfer Button", "Transfer", "", "[desc] Payment Successful￥19.00", "Payment Successful", "19.00",
            "申梦上荷（吉浦路店）", "￥19.00", "Payment method", "Balance", "Done", "[desc] 完成", "Done", "Translate",
        )
        val p = PaymentParsers.parseSuccessScreen(alipay, "com.eg.android.AlipayGphone.AlipayLogin", texts, now, null)
        assertEquals(1900L, p?.amountMinor)
        assertEquals("申梦上荷（吉浦路店）", p?.merchant)
        assertEquals("Balance", p?.method)
    }

    @Test
    fun transferCashierGivesRecipient() {
        val texts = listOf(
            "[desc] Close", "Transfer to KIRILL(* KIRILL)", "[desc] Payment amount: 26.00 yuan",
            "[desc] Selected,Balance,Description of payment channel content: Payment toolschannel",
            "Balance", "Payment tools", "[desc] View all", "[desc] 密码共6位，已输入1位", "1", "2", "3",
        )
        val c = PaymentParsers.parseCashier(texts, now)
        assertEquals("KIRILL", c?.merchant)
        assertEquals(2600L, c?.amountMinor)
        assertEquals("张三", PaymentParsers.cleanMerchant("转账给张三(*三)"))
    }

    @Test
    fun weixinPayNotification() {
        // Real notification, English WeChat, Oct 13.
        val p = PaymentParsers.parseNotification("com.tencent.mm", "Weixin Pay", "¥5.00 paid", now)
        assertEquals("expense", p?.direction)
        assertEquals(500L, p?.amountMinor)
        assertEquals("wechat", p?.app)
    }

    @Test
    fun alipayBillsList() {
        // Real capture of Alipay "Bills", Oct 13 2026 ~13:30 local.
        val now = java.util.Calendar.getInstance().apply { clear(); set(2026, 9, 13, 13, 31, 0) }.timeInMillis
        val texts = listOf(
            "Search transaction history", "Search", "All", "Expenses", "Oct", "Sent", "¥", "1,505.83", "Analysis",
            "哈啰出行车费，-2.50元，Auto debit successful，TransportAuto debit successful，，Today 13:05",
            "申梦上荷（吉浦路店），-19.00元，，Food，，Today 11:59",
            "收款-KIRILL，-13.00元，，Transfers，，Today 10:24",
            "扫收钱码付款-给韩学林，-20.00元，，Food，，Yesterday 13:00",
            "上海公交-20路-2026-10-11 10:49:53，-2.00元，，Transport，，10-11 12:49",
            "美团-美团订单-美团骑行-单车-骑行费-2026-10-10 21:27:06，-1.50元，Auto debit successful，LifeAuto debit successful，，10-10 21:51",
            "loading", "[desc] Back", "Translate",
        )
        val rows = PaymentParsers.parseBillRows(texts, now)
        assertEquals(6, rows.size)
        fun at(m: Int, d: Int, h: Int, mi: Int) = java.util.Calendar.getInstance().apply { clear(); set(2026, m - 1, d, h, mi, 0) }.timeInMillis

        val bike = rows[0]
        assertEquals("哈啰出行车费", bike.merchant)
        assertEquals(250L, bike.amountMinor)
        assertEquals("expense", bike.direction)
        assertEquals("Transport", bike.category)
        assertEquals(at(10, 13, 13, 5), bike.ts)
        assertEquals("bill", bike.source)

        assertEquals("Food", rows[1].category)
        assertEquals("KIRILL", rows[2].merchant)
        assertEquals("韩学林", rows[3].merchant)
        assertEquals(at(10, 12, 13, 0), rows[3].ts)
        assertEquals("上海公交-20路", rows[4].merchant)
        assertEquals(at(10, 11, 12, 49), rows[4].ts)
        assertEquals("美团-美团订单-美团骑行-单车-骑行费", rows[5].merchant)
        assertEquals("Life", rows[5].category)

        // Not the Bills screen -> nothing.
        assertEquals(0, PaymentParsers.parseBillRows(texts.drop(1), now).size)
    }

    @Test
    fun billTimeAcrossNewYear() {
        val jan2 = java.util.Calendar.getInstance().apply { clear(); set(2027, 0, 2, 9, 0, 0) }.timeInMillis
        val ts = PaymentParsers.parseBillTime("12-30 18:47", jan2)!!
        val c = java.util.Calendar.getInstance().apply { timeInMillis = ts }
        assertEquals(2026, c.get(java.util.Calendar.YEAR))
        assertNotNull(PaymentParsers.parseBillTime("昨天 07:50", jan2))
        assertNull(PaymentParsers.parseBillTime("Monday 10:00", jan2))
    }

    @Test
    fun wechatTransferNotices() {
        // Real (Oct 13): incoming transfer waiting and the friend accepting my transfer.
        assertEquals(
            PaymentParsers.TransferNotice("Alex", "income"),
            PaymentParsers.parseTransferNotice("Alex", "[Transfer] Accept transfer"),
        )
        assertEquals(
            PaymentParsers.TransferNotice("Alex", "expense"),
            PaymentParsers.parseTransferNotice("Alex", "[Transfer] Accepted"),
        )
        assertEquals(
            PaymentParsers.TransferNotice("李雷", "income"),
            PaymentParsers.parseTransferNotice("宿舍群", "李雷: [转账]请收款"),
        )
        assertNull(PaymentParsers.parseTransferNotice("Alex", "ok, transfer tomorrow"))
        assertEquals(2050L, TransferPrompts.parseAmount("20,5"))
        assertEquals(100L, TransferPrompts.parseAmount("¥1"))
        assertNull(TransferPrompts.parseAmount("сколько?"))
    }

    @Test
    fun wechatPayNotification() {
        val p = PaymentParsers.parseNotification("com.tencent.mm", "微信支付", "微信支付收款0.01元", now)
        assertEquals("income", p?.direction)
        assertEquals(1L, p?.amountMinor)
    }
}
