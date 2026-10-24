import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:budget_app/data/database.dart';
import 'package:budget_app/data/models.dart';
import 'package:budget_app/data/repository.dart';
import 'package:budget_app/import/read_statement.dart';
import 'package:budget_app/import/statement.dart';
import 'package:budget_app/import/statement_import.dart';
import 'package:fast_gbk/fast_gbk.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Statement files as banks and payment apps export them. All names, numbers and amounts are made up.

Uint8List _cp1251(String s) => Uint8List.fromList([
      for (final c in s.codeUnits)
        c < 0x80 ? c : c == 0x0401 ? 0xA8 : c == 0x0451 ? 0xB8 : c >= 0x0410 && c <= 0x044F ? c - 0x0410 + 0xC0 : 0x3F,
    ]);

/// Windows-1252, as German banks write CSV ("€" is 0x80).
Uint8List _latin1(String s) => Uint8List.fromList([for (final c in s.codeUnits) c == 0x20AC ? 0x80 : c]);

const alipayCsv = '''
------------------------------------------------------------------------------------
导出信息：
姓名：某某
支付宝账户：xxx@example.com
起始时间：[2026-09-01 00:00:00]    终止时间：[2026-09-30 23:59:59]
导出交易类型：[全部]
共5笔记录
------------------------支付宝（中国）网络技术有限公司  电子客户回单------------------------
交易时间,交易分类,交易对方,对方账号,商品说明,收/支,金额,收/付款方式,交易状态,交易订单号,商家订单号,备注,
2026-09-03 12:01:15,餐饮美食,上海某某餐厅,/,午餐,支出,38.50,余额,交易成功,2026090322001400001\t,T0001\t,,
2026-09-03 18:30:02,交通出行,上海地铁,/,地铁出行,支出,3.00,余额,交易成功,2026090322001400002\t,,,
2026-09-04 09:00:00,转账红包,张三,138****0000,转账,收入,200.00,余额,交易成功,2026090422001400003\t,,,
2026-09-05 10:00:00,投资理财,余额宝,/,转入余额宝,不计收支,500.00,余额,交易成功,2026090522001400004\t,,,
2026-09-06 11:00:00,日用百货,某某超市,/,购物,支出,25.00,余额,交易关闭,2026090622001400005\t,,,
''';

const tbankCsv = '"Дата операции";"Дата платежа";"Номер карты";"Статус";"Сумма операции";"Валюта операции";'
    '"Сумма платежа";"Валюта платежа";"Кэшбэк";"Категория";"MCC";"Описание";"Бонусы (включая кэшбэк)";'
    '"Округление на инвесткопилку";"Сумма операции с округлением"\n'
    '"12.09.2026 13:45:10";"13.09.2026";"*1234";"OK";"-1234,56";"RUB";"-1234,56";"RUB";"";"Супермаркеты";"5411";"Пятёрочка";"12,00";"0,00";"1234,56"\n'
    '"12.09.2026 09:00:00";"12.09.2026";"*1234";"FAILED";"-500,00";"RUB";"-500,00";"RUB";"";"Такси";"4121";"Такси";"0,00";"0,00";"500,00"\n'
    '"14.09.2026 20:00:00";"14.09.2026";"";"OK";"3000,00";"RUB";"3000,00";"RUB";"";"Пополнения";"";"Пополнение. Иван П.";"0,00";"0,00";"3000,00"\n';

const dkbCsv = '"Girokonto";"DE00 1203 0000 0000 0000 00"\n'
    '"Zeitraum:";"01.09.2026 - 30.09.2026"\n'
    '"Kontostand vom 30.09.2026:";"1.234,56 €"\n'
    '""\n'
    '"Buchungsdatum";"Wertstellung";"Status";"Zahlungspflichtige*r";"Zahlungsempfänger*in";"Verwendungszweck";"Umsatztyp";"IBAN";"Betrag (€)";"Gläubiger-ID";"Mandatsreferenz";"Kundenreferenz"\n'
    '"15.09.26";"15.09.26";"Gebucht";"Alex Beispiel";"REWE Markt GmbH";"Einkauf 2026-09-14";"Ausgang";"DE00000000000000000001";"-23,45";"";"";""\n'
    '"16.09.26";"16.09.26";"Gebucht";"Muster Arbeitgeber GmbH";"Alex Beispiel";"Gehalt September";"Eingang";"DE00000000000000000002";"2.100,00";"";"";""\n'
    '"17.09.26";"17.09.26";"Vorgemerkt";"Alex Beispiel";"Bäckerei Korn";"Kartenzahlung";"Ausgang";"";"-4,10";"";"";""\n';

const ingNlCsv = '"Datum","Naam / Omschrijving","Rekening","Tegenrekening","Code","Af Bij","Bedrag (EUR)","Mutatiesoort","Mededelingen"\n'
    '"20260918","Albert Heijn 1234","NL00INGB0000000000","","BA","Af","12,34","Betaalautomaat","Pasvolgnr: 001"\n'
    '"20260919","J. Jansen","NL00INGB0000000000","NL00RABO0000000001","OV","Bij","50,00","Overschrijving","Terugbetaling etentje"\n';

const camtXml = '''<?xml version="1.0" encoding="UTF-8"?>
<Document xmlns="urn:iso:std:iso:20022:tech:xsd:camt.053.001.08">
 <BkToCstmrStmt><Stmt>
  <Acct><Id><IBAN>DE00500105170000000000</IBAN></Id><Ccy>EUR</Ccy></Acct>
  <Ntry>
   <Amt Ccy="EUR">19.99</Amt><CdtDbtInd>DBIT</CdtDbtInd><Sts><Cd>BOOK</Cd></Sts>
   <BookgDt><Dt>2026-09-20</Dt></BookgDt><AcctSvcrRef>REF-1</AcctSvcrRef>
   <AddtlNtryInf>Kartenzahlung</AddtlNtryInf>
   <NtryDtls><TxDtls><RltdPties><Cdtr><Pty><Nm>Drogerie Beispiel</Nm></Pty></Cdtr></RltdPties>
   <RmtInf><Ustrd>Einkauf Filiale 12</Ustrd></RmtInf></TxDtls></NtryDtls>
  </Ntry>
  <Ntry>
   <Amt Ccy="EUR">5.00</Amt><CdtDbtInd>CRDT</CdtDbtInd><Sts><Cd>PDNG</Cd></Sts>
   <BookgDt><Dt>2026-09-21</Dt></BookgDt>
  </Ntry>
 </Stmt></BkToCstmrStmt>
</Document>''';

const mt940 = ''':20:STARTUMS
:25:12030000/1234567890
:28C:0
:60F:C260920EUR1000,00
:61:2609220922DR42,50NDDTNONREF
:86:106?00KARTENZAHLUNG?20SVWZ+Tankstelle 12?32Tank GmbH
:61:2609230923CR100,00NTRFNONREF
:86:166?00GUTSCHRIFT?20SVWZ+Rueckzahlung?32Kim Beispiel
:62F:C260923EUR1057,50
-''';

/// As PDFBox reads a real Sber statement (sorted by position), numbers changed.
const sberPdfText = '''900 www.sberbank.ru Заказано в СберБанк Онлайн
Выписка по счёту дебетовой карты
За период 01.09.2026 — 30.09.2026
Владелец счёта
Иван Петрович С. Остаток на 01.09.2026 10 000,00
Номер счёта 40817 810 0 0000 0000000 Пополнение 5 000,00
Карта Visa Classic •••• 1234 Списание 845,20
Расшифровка операций
ДАТА ОПЕРАЦИИ (МСК) КАТЕГОРИЯ СУММА В ВАЛЮТЕ СЧЁТА ОСТАТОК СРЕДСТВ
Дата обработки1 Описание операции Сумма в валюте В валюте счёта
и код авторизации операции2
22.09.2026 09:12 Перевод СБП +5 000,00 14 154,80
22.09.2026 654321 ВТБ. Операция по карте ****1234
21.09.2026 13:05 Супермаркеты 845,20 9 154,80
21.09.2026 123456 MAGAZIN PRODUKTY Moscow RUS. Операция по карте ****1234
*
Дата формирования документа 30.09.2026
40601F002F4DFCA791B6A6356AAD4786
ПАО Сбербанк. Генеральная лицензия Банка России на осуществление банковских операций № 1481 от 11.08.2015.
''';

/// The rows of a WeChat Pay export ("用于个人对账", xlsx; here as CSV): times are Excel day numbers.
const wechatCsv = '''微信支付账单明细
微信昵称：[某某]
起始时间：[2026-07-24 00:00:00] 终止时间：[2026-10-24 09:35:58]
共4笔记录
----------------------微信支付账单明细列表--------------------
交易时间,交易类型,交易对方,商品,收/支,金额(元),支付方式,当前状态,交易单号,商户单号,备注
46318.80929398148,转账,Alex,转账备注:微信转账,收入,250,/,已存入零钱,100005000120261023,/,/
46316.7562962963,商户消费,上海某某大学,聚合充值_A1,支出,50,零钱,支付成功,450000052120261021,21128484,/
46314.73,商户消费,全家,上海全家便利店,支出,4.9,工商银行储蓄卡(0000),支付成功,450000052120261019,/,/
46313.5,转账-退款,Alex,转账备注:微信转账,收入,1,/,已到账,100005000120261018,/,/
''';

void main() {
  group('numbers and dates', () {
    test('amounts in the ways statements write them', () {
      expect(parseAmount('1 234,56'), 123456);
      expect(parseAmount('-1.234,56'), -123456);
      expect(parseAmount('1,234.56'), 123456);
      expect(parseAmount('¥12.00'), 1200);
      expect(parseAmount('+12,34'), 1234);
      expect(parseAmount('−5'), -500);
      expect(parseAmount('2.100,00'), 210000);
      expect(parseAmount('12,34-'), -1234);
      expect(parseAmount('1.234'), 123400);
      expect(parseAmount('42,5'), 4250);
      expect(parseAmount('abc'), isNull);
    });

    test('dates', () {
      expect(parseStatementDate('2026-09-03 12:01:15'), (DateTime(2026, 9, 3, 12, 1, 15), true));
      expect(parseStatementDate('15.09.26'), (DateTime(2026, 9, 15), false));
      expect(parseStatementDate('20260918'), (DateTime(2026, 9, 18), false));
      expect(parseStatementDate('2026/9/3 8:05'), (DateTime(2026, 9, 3, 8, 5), true));
      expect(parseStatementDate('12.09.2026 13:45:10')?.$1, DateTime(2026, 9, 12, 13, 45, 10));
      expect(parseStatementDate('Итого'), isNull);
    });
  });

  group('reading files', () {
    Future<Statement> read(String name, Uint8List bytes) async => (await readStatementFile(name, bytes)).single;

    test('Alipay CSV in GBK: skips the money market fund and the closed order', () async {
      final s = await read('alipay_record.csv', Uint8List.fromList(gbk.encode(alipayCsv)));
      expect(s.format, 'alipay');
      expect(s.app, 'alipay');
      final ok = s.rows.where((r) => r.skip == null).toList();
      expect(ok, hasLength(3));
      expect(ok.first.payee, '上海某某餐厅');
      expect(ok.first.amountMinor, 3850);
      expect(ok.first.currency, 'CNY');
      expect(ok.first.category, '餐饮美食');
      expect(ok.first.id, '2026090322001400001');
      expect(ok[2].kind, TxnKind.income);
      expect(s.rows.firstWhere((r) => r.amountMinor == 50000).skip, 'neutral');
      expect(s.rows.firstWhere((r) => r.amountMinor == 2500).skip, 'failed');
    });

    test('Alipay CSV inside a password-protected ZIP', () async {
      final archive = Archive()..addFile(ArchiveFile.bytes('alipay_record.csv', gbk.encode(alipayCsv)));
      final zip = Uint8List.fromList(ZipEncoder(password: '123456').encodeBytes(archive));
      await expectLater(readStatementFile('statement.zip', zip), throwsA(isA<StatementPasswordNeeded>()));
      final s = (await readStatementFile('statement.zip', zip, password: '123456')).single;
      expect(s.format, 'alipay');
    });

    test('T-Bank CSV in Windows-1251: account currency, failed operations skipped', () async {
      final s = await read('operations.csv', _cp1251(tbankCsv));
      expect(s.format, 'tbank');
      expect(s.rows, hasLength(3));
      final shop = s.rows.first;
      expect(shop.amountMinor, 123456);
      expect(shop.kind, TxnKind.expense);
      expect(shop.mcc, '5411');
      expect(shop.payee, 'Пятёрочка');
      expect(shop.hasTime, isTrue);
      expect(s.rows[1].skip, 'failed');
      expect(s.rows[2].kind, TxnKind.income);
    });

    test('DKB CSV: preamble, payer/payee by direction, pending skipped', () async {
      final s = await read('DKB-Umsaetze.csv', _latin1(dkbCsv));
      expect(s.app, 'dkb');
      expect(s.rows, hasLength(3));
      expect(s.rows[0].payee, 'REWE Markt GmbH');
      expect(s.rows[0].amountMinor, 2345);
      expect(s.rows[0].currency, 'EUR');
      expect(s.rows[1].payee, 'Muster Arbeitgeber GmbH');
      expect(s.rows[1].kind, TxnKind.income);
      expect(s.rows[2].skip, 'pending');
    });

    test('ING (NL) CSV: Af/Bij gives the direction', () async {
      final s = await read('NL00INGB_01-09-2026.csv', utf8.encode(ingNlCsv));
      expect(s.rows.map((r) => r.kind), [TxnKind.expense, TxnKind.income]);
      expect(s.rows.first.payee, 'Albert Heijn 1234');
      expect(s.rows.first.time, DateTime(2026, 9, 18));
    });

    test('CAMT.053', () async {
      final s = await read('camt.xml', utf8.encode(camtXml));
      expect(s.format, 'camt');
      expect(s.accountRef, 'DE00500105170000000000');
      expect(s.rows.first.payee, 'Drogerie Beispiel');
      expect(s.rows.first.amountMinor, 1999);
      expect(s.rows.first.id, 'REF-1');
      expect(s.rows[1].skip, 'pending');
    });

    test('MT940 with structured German details', () async {
      final s = await read('umsaetze.sta', _latin1(mt940));
      expect(s.rows, hasLength(2));
      expect(s.rows[0].kind, TxnKind.expense);
      expect(s.rows[0].amountMinor, 4250);
      expect(s.rows[0].payee, 'Tank GmbH');
      expect(s.rows[0].details, 'Tankstelle 12');
      expect(s.rows[1].kind, TxnKind.income);
      expect(s.rows[1].payee, 'Kim Beispiel');
    });

    test('Sber PDF text: unsigned is an expense, "+" an income', () async {
      final list = await readStatementFile('Выписка.pdf', Uint8List.fromList(utf8.encode('%PDF-1.7')),
          readPdf: (_) async => sberPdfText);
      final s = list.single;
      expect(s.app, 'sber');
      expect(s.rows, hasLength(2));
      final shop = s.rows.firstWhere((r) => r.kind == TxnKind.expense);
      expect(shop.amountMinor, 84520);
      expect(shop.category, 'Супермаркеты');
      expect(shop.payee, contains('MAGAZIN PRODUKTY'));
      // The footnote mark and the document's footer are not part of it.
      expect(shop.details, 'MAGAZIN PRODUKTY Moscow RUS. Операция по карте ****1234');
      final transfer = s.rows.firstWhere((r) => r.kind == TxnKind.income);
      expect(transfer.amountMinor, 500000);
      expect(transfer.payee, 'ВТБ');
      expect(transfer.time, DateTime(2026, 9, 22, 9, 12));
    });

    test('WeChat Pay export: Excel day numbers, payment method kept', () async {
      final s = (await readStatementFile('微信支付账单流水文件.csv', utf8.encode(wechatCsv))).single;
      expect(s.format, 'wechat');
      expect(s.rows, hasLength(4));
      expect(s.rows[0].time, DateTime(2026, 10, 23, 19, 25, 23));
      expect(s.rows[0].kind, TxnKind.income);
      expect(s.rows[0].amountMinor, 25000);
      expect(s.rows[2].amountMinor, 490);
      expect(s.rows[2].method, '工商银行储蓄卡(0000)');
      expect(s.rows[1].id, '450000052120261021');
    });

    test('a file that is not a statement', () async {
      await expectLater(readStatementFile('notes.txt', utf8.encode('hello\nworld')), throwsA(isA<UnknownStatement>()));
    });
  });

  group('adding to the app', () {
    sqfliteFfiInit();
    late Directory tmp;
    late Repository repo;

    setUp(() async {
      tmp = Directory.systemTemp.createTempSync('budget_stmt_');
      repo = Repository(await openAppDatabase(factory: databaseFactoryFfi, path: '${tmp.path}/b.db'));
    });
    tearDown(() async {
      await repo.db.close();
      tmp.deleteSync(recursive: true);
    });

    Future<Account> alipayAccount() async {
      final existing = (await repo.accounts()).where((a) => a.type == 'alipay').firstOrNull;
      if (existing != null) return existing;
      final id = await repo.addAccount('Alipay', 'CNY', 'alipay');
      return (await repo.accounts()).firstWhere((a) => a.id == id);
    }

    test('captured payments are recognised, missed ones added, a second import adds nothing', () async {
      final account = await alipayAccount();
      // The lunch was caught from the payment screen a minute after the statement's time.
      await repo.insertTxn(Txn(
        time: DateTime(2026, 9, 3, 12, 2),
        amountMinor: 3850,
        currency: 'CNY',
        kind: TxnKind.expense,
        accountId: account.id,
        source: 'alipay:screen',
        needsReview: true,
      ));
      final s = (await readStatementFile('a.csv', Uint8List.fromList(gbk.encode(alipayCsv)))).single;
      expect((await guessStatementAccount(repo, s))?.id, account.id);

      final plan = await planStatementImport(repo, s, account);
      expect(plan.known, hasLength(1));
      expect(plan.toAdd, hasLength(2));
      expect(plan.skipped, hasLength(2));
      expect(await applyStatementImport(repo, plan), 2);

      final all = await repo.txnsBetween(DateTime(2026), DateTime(2027));
      expect(all, hasLength(3));
      final lunch = all.firstWhere((t) => t.amountMinor == 3850);
      expect(lunch.merchant, '上海某某餐厅');
      expect(lunch.categoryId, isNotNull);
      expect(lunch.needsReview, isFalse);
      final metro = all.firstWhere((t) => t.amountMinor == 300);
      expect(metro.source, 'alipay:statement');
      final transport = (await repo.categories()).firstWhere((c) => c.key == 'transport');
      expect(metro.categoryId, transport.id);

      final again = await planStatementImport(repo, s, account);
      expect(again.toAdd, isEmpty);
      expect(await applyStatementImport(repo, again), 0);
      expect(await repo.txnsBetween(DateTime(2026), DateTime(2027)), hasLength(3));
    });

    test('a bank booking days later still matches the card payment', () async {
      final id = await repo.addAccount('Sber', 'RUB', 'sber');
      final account = (await repo.accounts()).firstWhere((a) => a.id == id);
      await repo.insertTxn(Txn(
        time: DateTime(2026, 9, 19, 18, 40),
        amountMinor: 84520,
        currency: 'RUB',
        kind: TxnKind.expense,
        accountId: id,
        source: 'sber:notification',
      ));
      final s = Statement(format: 'csv', app: 'sber', rows: [
        StatementRow(time: DateTime(2026, 9, 21), hasTime: false, kind: TxnKind.expense, amountMinor: 84520, currency: 'RUB', payee: 'Shop'),
      ]);
      final plan = await planStatementImport(repo, s, account);
      expect(plan.known, hasLength(1));
      expect(plan.toAdd, isEmpty);
    });

    test('an operation the user deleted is not brought back', () async {
      final account = await alipayAccount();
      final t = Txn(
          time: DateTime(2026, 9, 3, 18, 30), amountMinor: 300, currency: 'CNY', kind: TxnKind.expense, source: 'alipay:screen');
      await repo.dismiss(t);
      final s = (await readStatementFile('a.csv', Uint8List.fromList(gbk.encode(alipayCsv)))).single;
      final plan = await planStatementImport(repo, s, account);
      expect(plan.skipped.where((r) => r.reason == 'deleted'), hasLength(1));
    });

    test('merchant category codes', () {
      expect(mccCategoryKey('5411', TxnKind.expense), 'food');
      expect(mccCategoryKey('4121', TxnKind.expense), 'transport');
      expect(mccCategoryKey('5912', TxnKind.expense), 'health');
      expect(mccCategoryKey('5411', TxnKind.income), isNull);
    });
  });
}
