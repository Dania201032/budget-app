import 'dart:convert';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/services.dart';

import '../data/models.dart';
import '../data/repository.dart';

/// A payment detected by the native capture services (see android/.../capture/).
class CapturedPayment {
  /// screen | notification | bill (Alipay Bills row) | prompt (WeChat transfer, amount asked) | prompt_answer
  final String source;
  final String app; // alipay | wechat
  final TxnKind kind;
  final int amountMinor;
  final String currency;
  final String? merchant;
  final String? method;
  final DateTime time;
  final String raw;

  /// Category as named by the payment app (Alipay Bills: "Food", "Transport"…).
  final String? category;
  final int? promptId;

  CapturedPayment({
    required this.source,
    required this.app,
    required this.kind,
    required this.amountMinor,
    required this.currency,
    required this.merchant,
    required this.method,
    required this.time,
    required this.raw,
    this.category,
    this.promptId,
  });

  factory CapturedPayment.fromJson(Map<String, dynamic> j) => CapturedPayment(
        source: j['source'] as String,
        app: j['app'] as String,
        kind: j['direction'] == 'income' ? TxnKind.income : TxnKind.expense,
        amountMinor: (j['amountMinor'] as num).toInt(),
        currency: j['currency'] as String,
        merchant: j['merchant'] as String?,
        method: j['method'] as String?,
        time: DateTime.fromMillisecondsSinceEpoch((j['ts'] as num).toInt()),
        raw: j['raw'] as String? ?? '',
        category: j['category'] as String?,
        promptId: (j['promptId'] as num?)?.toInt(),
      );
}

/// Splits [t] into [parts] equal shares: mine counts in the budget, the rest is owed by unnamed friends
/// (closed automatically when a transfer of exactly that amount comes in).
Future<void> splitEqually(Repository repo, Txn t, int parts) async {
  final total = t.amountMinor;
  final friendShare = total ~/ parts;
  final mine = total - friendShare * (parts - 1);
  await repo.updateTxn(t.copyWith(shareMinor: () => mine));
  await repo.setDebts(t.id!, [for (var i = 0; i < parts - 1; i++) (null, friendShare)], t.currency);
}

/// Alipay Bills categories (English and Chinese UI) -> built-in category keys.
const alipayCategoryMap = <String, String>{
  'Food': 'food', '餐饮美食': 'food',
  'Transport': 'transport', '交通出行': 'transport',
  'Daily': 'shopping', '日用百货': 'shopping',
  'Shopping': 'shopping', 'Clothing': 'shopping', '服饰装扮': 'shopping', 'Electronics': 'shopping', '数码电器': 'shopping',
  'Education': 'education', '教育培训': 'education',
  'Entertainment': 'fun', '文化休闲': 'fun', '休闲娱乐': 'fun',
  'Medical': 'health', 'Health': 'health', '医疗健康': 'health',
  'Housing': 'housing', '住房物业': 'housing',
  'Top-ups': 'subscriptions', '充值缴费': 'subscriptions',
  'Life': 'other', '生活服务': 'other',
  'Transfers': 'transfers_out', '转账红包': 'transfers_out',
  // Seen in Alipay's exported statements (交易明细).
  'Travel': 'fun', '酒店旅游': 'fun', '运动户外': 'fun', '爱车养车': 'transport',
  '商业服务': 'other', '其他': 'other', '收入': 'other', '公益捐赠': 'other', '保险': 'other',
  '母婴亲子': 'shopping', '宠物': 'shopping', '美容美发': 'health',
};

/// Built-in category key for an Alipay category, adjusted to the direction.
String? alipayCategoryKey(String? alipayCategory, TxnKind kind) {
  final key = alipayCategoryMap[alipayCategory];
  if (key == null || kind == TxnKind.expense) return key;
  return switch (key) { 'transfers_out' => 'transfers_in', 'other' => 'other_income', _ => null };
}

/// How far back a bank's history is read (older operations are in the opening balance).
const bankHistoryDays = 62;

/// Categories of Russian/Kazakh bank apps' histories -> built-in category keys.
const bankCategoryMap = <String, String>{
  'супермаркеты': 'food', 'продукты': 'food', 'рестораны': 'food', 'кафе и рестораны': 'food',
  'рестораны и кафе': 'food', 'фастфуд': 'food', 'кафе': 'food', 'еда': 'food',
  'транспорт': 'transport', 'такси': 'transport', 'местный транспорт': 'transport', 'топливо': 'transport',
  'азс': 'transport', 'авиабилеты': 'transport', 'ж/д билеты': 'transport',
  'маркетплейсы': 'shopping', 'одежда и обувь': 'shopping', 'одежда': 'shopping', 'покупки': 'shopping',
  'дом и ремонт': 'shopping', 'электроника': 'shopping', 'различные товары': 'shopping',
  'здоровье': 'health', 'аптеки': 'health', 'медицина': 'health', 'красота': 'health',
  'развлечения': 'fun', 'кино': 'fun', 'отдых': 'fun', 'путешествия': 'fun',
  'образование': 'education', 'книги': 'education',
  'жкх': 'housing', 'коммунальные платежи': 'housing', 'аренда': 'housing',
  'связь': 'subscriptions', 'мобильная связь': 'subscriptions', 'интернет': 'subscriptions',
  'подписки': 'subscriptions', 'цифровые товары': 'subscriptions', 'связь, интернет и тв': 'subscriptions',
  'переводы': 'transfers_out', 'перевод': 'transfers_out', 'аударымдар': 'transfers_out',
  'наличные': 'other', 'снятие наличных': 'other',
  // German and Dutch bank apps (N26, bunq, ING, DKB…)
  'lebensmittel': 'food', 'supermarkt': 'food', 'supermärkte': 'food', 'restaurants': 'food', 'essen & trinken': 'food',
  'essen und trinken': 'food', 'bars & restaurants': 'food', 'boodschappen': 'food', 'eten en drinken': 'food',
  'eten & drinken': 'food', 'uit eten': 'food', 'groceries': 'food', 'food & drink': 'food',
  'transport': 'transport', 'verkehr': 'transport', 'mobilität': 'transport', 'reisen': 'transport',
  'auto & transport': 'transport', 'vervoer': 'transport', 'reizen': 'transport', 'tanken': 'transport',
  'shopping': 'shopping', 'einkaufen': 'shopping', 'winkelen': 'shopping', 'kleidung': 'shopping', 'kleding': 'shopping',
  'gesundheit': 'health', 'gesundheit & drogerie': 'health', 'drogerie': 'health', 'gezondheid': 'health',
  'freizeit': 'fun', 'unterhaltung': 'fun', 'freizeit & unterhaltung': 'fun', 'vrije tijd': 'fun', 'uitgaan': 'fun',
  'entertainment': 'fun', 'bildung': 'education', 'onderwijs': 'education',
  'wohnen': 'housing', 'miete': 'housing', 'haushalt & wohnen': 'housing', 'wonen': 'housing', 'huur': 'housing',
  'abonnements': 'subscriptions', 'abos': 'subscriptions', 'medien & elektronik': 'shopping',
  'abonnementen': 'subscriptions', 'telefoon & internet': 'subscriptions', 'subscriptions': 'subscriptions',
  'überweisungen': 'transfers_out', 'überweisung': 'transfers_out', 'overboekingen': 'transfers_out',
  'transfers': 'transfers_out', 'bargeld': 'other', 'geldautomat': 'other', 'contant geld': 'other', 'geldopname': 'other',
};

/// Built-in category key for a bank's history category, adjusted to the direction.
String? bankCategoryKey(String? bankCategory, TxnKind kind) {
  final key = bankCategoryMap[bankCategory?.toLowerCase().trim()];
  if (key == null || kind == TxnKind.expense) return key;
  return switch (key) { 'transfers_out' => 'transfers_in', _ => null };
}

/// One bank notification as seen by the native listener (see BankLog.kt).
class BankLogEntry {
  final DateTime time;
  final String app; // bank key: sber, vtb…
  final String bank; // shown name
  final String title;
  final String text;
  /// recorded | promo | code | declined | no_amount | not_operation
  final String reason;
  final TxnKind? kind;
  final int? amountMinor;
  final String? currency;
  final String? merchant;

  const BankLogEntry({
    required this.time,
    required this.app,
    required this.bank,
    required this.title,
    required this.text,
    required this.reason,
    this.kind,
    this.amountMinor,
    this.currency,
    this.merchant,
  });

  bool get recorded => reason == 'recorded';

  factory BankLogEntry.fromJson(Map<String, dynamic> j) => BankLogEntry(
        time: DateTime.fromMillisecondsSinceEpoch((j['ts'] as num).toInt()),
        app: j['app'] as String? ?? '',
        bank: j['bank'] as String? ?? '',
        title: j['title'] as String? ?? '',
        text: j['text'] as String? ?? '',
        reason: j['reason'] as String? ?? '',
        kind: j['direction'] == null ? null : (j['direction'] == 'income' ? TxnKind.income : TxnKind.expense),
        amountMinor: (j['amountMinor'] as num?)?.toInt(),
        currency: j['currency'] as String?,
        merchant: j['merchant'] as String?,
      );

  /// For "Add manually": the first amount in the text, if any ("1 450,50 ₽" -> 145050).
  int? get guessedAmountMinor {
    final m = RegExp(r'(\d{1,3}(?:[\s  ]\d{3})+|\d+)(?:[.,](\d{1,2}))?\s?(₽|р|руб|₸|тг|RUB|KZT)', caseSensitive: false)
        .firstMatch('$title $text');
    if (m == null) return null;
    final whole = int.parse(m.group(1)!.replaceAll(RegExp(r'[\s  ]'), ''));
    return whole * 100 + int.parse((m.group(2) ?? '0').padRight(2, '0'));
  }
}

class CaptureStatus {
  final bool accessibility;
  final bool notifications;
  final bool postNotifications;

  /// Android API level; 33+ may show "Restricted settings" for an app installed from a file.
  final int sdk;

  /// Android still keeps this app's special accesses locked ("Restricted settings": installed
  /// from a file, not yet allowed in App info).
  final bool restricted;

  const CaptureStatus(
      {this.accessibility = false, this.notifications = false, this.postNotifications = false, this.sdk = 0, this.restricted = false});
  bool get allOn => accessibility && notifications && postNotifications;

  /// Recording works: the payment notifications are read and "Recorded" can be shown. Reading
  /// the payment screen counts only where it is needed ([needsScreen]: Alipay, WeChat).
  bool ready({required bool needsScreen}) => notifications && postNotifications && (accessibility || !needsScreen);

  bool get mayBeRestricted => sdk >= 33 && !(accessibility && notifications);
}

class CaptureService {
  static const _channel = MethodChannel('budget/capture');

  Future<CaptureStatus> status() async {
    try {
      final m = Map<String, dynamic>.from(await _channel.invokeMethod('status'));
      return CaptureStatus(
        accessibility: m['accessibility'] == true,
        notifications: m['notifications'] == true,
        postNotifications: m['postNotifications'] == true,
        sdk: (m['sdk'] as num?)?.toInt() ?? 0,
        restricted: m['restricted'] == true,
      );
    } on MissingPluginException {
      return const CaptureStatus();
    }
  }

  /// Language for the native notifications ("Recorded: …", transfer prompts).
  Future<void> setLanguage(String lang) async {
    try {
      await _channel.invokeMethod('setLanguage', {'lang': lang});
    } on MissingPluginException {
      // tests / non-Android
    }
  }

  /// Takes a receipt photo with the system camera; the picture's path, or null.
  Future<String?> takeReceiptPhoto() async {
    try {
      return await _channel.invokeMethod<String>('takeReceiptPhoto');
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  /// A receipt photo read on the phone: (its text, its QR code), each null if not found.
  Future<(String?, String?)> scanReceipt(String path) async {
    try {
      final r = await _channel.invokeMapMethod<String, Object?>('scanReceipt', {'path': path});
      return (r?['text'] as String?, r?['qr'] as String?);
    } on PlatformException {
      return (null, null);
    } on MissingPluginException {
      return (null, null);
    }
  }

  /// The text in a picture shared to the app ("Share → Budget"), read on the phone; null if none.
  Future<String?> readSharedImage(String uri) async {
    try {
      return await _channel.invokeMethod<String>('readSharedImage', {'uri': uri});
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  /// What "Split…" on a notification asked to open, once.
  Future<Map<String, Object?>?> takePendingAction() async {
    try {
      return await _channel.invokeMapMethod<String, Object?>('takePendingAction');
    } on MissingPluginException {
      return null;
    }
  }

  Future<void> openAccessibility() => _channel.invokeMethod('openAccessibility');
  Future<void> openNotificationAccess() => _channel.invokeMethod('openNotificationAccess');
  Future<void> openAppInfo() => _channel.invokeMethod('openAppInfo');
  /// Asks for the permission to show notifications (Android 13+, iPhone); no dialog once answered.
  Future<void> requestPostNotifications() async {
    try {
      await _channel.invokeMethod('requestPostNotifications');
    } on MissingPluginException {
      // tests
    }
  }

  /// Reminders of regular payments: {ts, title, text}; the phone notifies at those times, even
  /// with the app closed. Replaces the previous list.
  Future<void> setReminders(List<Map<String, Object?>> reminders) async {
    try {
      await _channel.invokeMethod('setReminders', {'json': jsonEncode(reminders)});
    } on MissingPluginException {
      // tests
    }
  }

  /// The last bank notifications and what was done with each, newest first.
  Future<List<BankLogEntry>> bankLog() async {
    final String raw;
    try {
      raw = await _channel.invokeMethod<String>('bankLog') ?? '';
    } on MissingPluginException {
      return const [];
    }
    final out = <BankLogEntry>[];
    for (final line in const LineSplitter().convert(raw)) {
      if (line.trim().isEmpty) continue;
      try {
        out.add(BankLogEntry.fromJson(jsonDecode(line) as Map<String, dynamic>));
      } catch (e) {
        debugPrint('Bad bank log line: $e');
      }
    }
    return out.reversed.toList();
  }

  Future<void> clearBankLog() async {
    try {
      await _channel.invokeMethod('clearBankLog');
    } on MissingPluginException {
      // tests
    }
  }

  Future<List<CapturedPayment>> consumeInbox() async {
    final String raw;
    try {
      raw = await _channel.invokeMethod<String>('consumeInbox') ?? '';
    } on MissingPluginException {
      return const [];
    }
    final out = <CapturedPayment>[];
    for (final line in const LineSplitter().convert(raw)) {
      if (line.trim().isEmpty) continue;
      try {
        out.add(CapturedPayment.fromJson(jsonDecode(line) as Map<String, dynamic>));
      } catch (e) {
        debugPrint('Bad capture line: $e');
      }
    }
    return out;
  }
}

/// Turns captured payments into transactions: merges the screen + notification of the same
/// payment, applies learned merchant categories, marks the rest for review.
class CaptureImporter {
  final Repository repo;
  CaptureImporter(this.repo);

  /// Returns the number of new transactions.
  Future<int> importAll(List<CapturedPayment> payments) async {
    if (payments.isEmpty) return 0;
    // Shared budget: my payments go to my own or the common accounts; the first one of a payment
    // app whose account belongs to someone else gets an account of my own.
    if (repo.me != null) {
      final all = await repo.accounts();
      final mine = await repo.myAccounts();
      for (final app in payments.map((p) => p.app).toSet()) {
        if (mine.any((a) => a.type == app)) continue;
        final theirs = all.where((a) => a.type == app).firstOrNull;
        if (theirs != null) await repo.addAccount(theirs.name, theirs.currency, app, owner: repo.me);
      }
    }
    final accounts = await repo.myAccounts();
    final categories = await repo.categories();
    // Only Excel *expenses* mark the covered history: the income sheet may hold future, expected incomes.
    final excelUntil = await repo.lastDayOf('excel', TxnKind.expense);
    var created = 0;
    // Stable order: a transfer prompt and its answer share the same time, and the answer must come
    // after the prompt (Dart's sort is not stable, so ties are broken by the inbox order).
    final order = {for (var i = 0; i < payments.length; i++) payments[i]: i};
    payments.sort((a, b) {
      final byTime = a.time.compareTo(b.time);
      return byTime != 0 ? byTime : order[a]!.compareTo(order[b]!);
    });
    int? accountFor(String app) => accounts.where((a) => a.type == app).firstOrNull?.id;

    /// Bank accounts appear by themselves on the first notification of a bank ("Сбер", "Kaspi"…).
    Future<int?> bankAccount(CapturedPayment p) async {
      final existing = accountFor(p.app);
      if (existing != null || p.app == 'sms') return existing;
      // The user's own "ВТБ" account (created by hand) becomes this bank's account.
      final own = await repo.accountForBank(p.app, p.currency);
      if (own != null) {
        accounts
          ..clear()
          ..addAll(await repo.myAccounts());
        return own;
      }
      final id = await repo.addAccount(p.method ?? p.app, p.currency, p.app, owner: repo.me);
      accounts.add(Account(id: id, name: p.method ?? p.app, currency: p.currency, type: p.app, owner: repo.me));
      return id;
    }

    for (final p in payments) {
      switch (p.source) {
        case 'payee':
          // "Where?" answered on the "Recorded" notification of a payment without a payee (WeChat Pay).
          final t = await repo.findSamePayment(appPrefix: p.app, kind: p.kind, amountMinor: p.amountMinor, time: p.time);
          if (t != null && p.merchant != null) {
            final categoryId = t.categoryId ?? await repo.categoryForMerchant(p.merchant!, t.kind);
            await repo.updateTxn(t.copyWith(
              merchant: () => p.merchant,
              categoryId: () => categoryId,
              needsReview: t.needsReview && categoryId == null,
            ));
          }
          continue;
        case 'split':
          // "÷N" pressed on the "Recorded" notification.
          final t = await repo.findSamePayment(
              appPrefix: p.app, kind: TxnKind.expense, amountMinor: p.amountMinor, time: p.time);
          final parts = p.promptId ?? 2;
          if (t != null && parts > 1) await splitEqually(repo, t, parts);
          // "For a friend": none of it is mine, the friend owes all of it.
          if (t != null && parts == 0) {
            await repo.updateTxn(t.copyWith(shareMinor: () => 0));
            await repo.setDebts(t.id!, [(null, t.amountMinor)], t.currency);
          }
          continue;
        case 'bill':
          if (p.app == 'alipay' || p.app == 'wechat') {
            if (await _importBillRow(p, categories, excelUntil, accountFor(p.app))) created++;
            continue;
          }
          // A Google Wallet payment of that day is this bank's row: it becomes the bank's operation.
          final paid = await repo.findWalletTwin(
              wallet: false, kind: p.kind, amountMinor: p.amountMinor, currency: p.currency, time: p.time, dateOnly: true);
          if (paid != null) await _adoptWalletPayment(paid, p, await bankAccount(p));
          if (await _importBankRow(p, categories, excelUntil, () => bankAccount(p))) created++;
          continue;
        case 'prompt':
          // Already answered (or a re-delivered prompt): nothing to add.
          if (await repo.findByRaw('prompt:${p.promptId}') != null) continue;
          await repo.insertTxn(Txn(
            time: p.time,
            amountMinor: 0,
            currency: p.currency,
            kind: p.kind,
            accountId: accountFor(p.app),
            merchant: p.merchant,
            source: '${p.app}:prompt',
            needsReview: true,
            raw: 'prompt:${p.promptId}',
          ));
          created++;
          continue;
        case 'prompt_answer':
          final pending = await repo.findByRaw('prompt:${p.promptId}');
          if (p.amountMinor == 0) {
            if (pending != null) await repo.deleteTxn(pending.id!);
            continue;
          }
          final categoryId = p.merchant == null ? null : await repo.categoryForMerchant(p.merchant!, p.kind);
          if (pending != null) {
            await repo.updateTxn(pending.copyWith(
              amountMinor: p.amountMinor,
              categoryId: () => pending.categoryId ?? categoryId,
              needsReview: (pending.categoryId ?? categoryId) == null,
            ));
            await _settle(pending.id!);
          } else {
            final id = await repo.insertTxn(Txn(
              time: p.time,
              amountMinor: p.amountMinor,
              currency: p.currency,
              kind: p.kind,
              categoryId: categoryId,
              accountId: accountFor(p.app),
              merchant: p.merchant,
              source: '${p.app}:prompt',
              needsReview: categoryId == null,
              raw: 'prompt:${p.promptId}',
            ));
            await _settle(id);
            created++;
          }
          continue;
      }

      if (p.source == 'screen' &&
          await repo.isRepeatedScreen(app: p.app, amountMinor: p.amountMinor, merchant: p.merchant, time: p.time)) {
        continue;
      }
      if (p.source == 'notification' &&
          await repo.isRepeatedNotification(app: p.app, amountMinor: p.amountMinor, raw: p.raw, time: p.time)) {
        continue;
      }
      final isBank = p.source == 'bank' || p.source == 'sms';
      // Paid by phone: Google Wallet and the card's bank both notify about the same payment.
      if (p.app == walletApp) {
        final bank = await repo.findWalletTwin(
            wallet: true, kind: p.kind, amountMinor: p.amountMinor, currency: p.currency, time: p.time);
        if (bank != null) {
          await repo.updateTxn(await _merge(bank, p));
          continue;
        }
      } else if (isBank) {
        final paid = await repo.findWalletTwin(
            wallet: false, kind: p.kind, amountMinor: p.amountMinor, currency: p.currency, time: p.time);
        if (paid != null) {
          await _adoptWalletPayment(paid, p, await bankAccount(p));
          continue;
        }
      }
      final twin = await repo.findCaptureTwin(
        app: p.app,
        kind: p.kind,
        amountMinor: p.amountMinor,
        time: p.time,
        sourceType: p.source,
      ) ??
          // A bank notification of an operation already read from the bank's history (rows may have no time).
          (isBank ? await _historyTwin(p) : null);
      if (twin != null) {
        await repo.updateTxn(await _merge(twin, p));
        await _settle(twin.id!);
        continue;
      }

      final categoryId = p.merchant == null ? null : await repo.categoryForMerchant(p.merchant!, p.kind);
      final id = await repo.insertTxn(Txn(
        time: p.time,
        amountMinor: p.amountMinor,
        currency: p.currency,
        kind: p.kind,
        categoryId: categoryId,
        accountId: isBank ? await bankAccount(p) : accountFor(p.app),
        merchant: p.merchant,
        note: isBank ? null : p.method,
        source: '${p.app}:${p.source}',
        needsReview: categoryId == null,
        raw: p.raw,
      ));
      await _settle(id);
      created++;
    }
    return created;
  }

  /// A friend's transfer may pay back a split bill.
  Future<void> _settle(int txnId) async {
    final t = await repo.txnById(txnId);
    if (t == null) return;
    // Money moved between my own accounts is neither spending nor income nor a friend's payback.
    if (await _ownTransfer(t)) return;
    await repo.settleDebtsWith(t);
  }

  /// Pairs transfers to myself recorded before the app knew about them (run once after the update).
  Future<int> pairEarlierTransfers() async {
    final now = DateTime.now();
    final txns = await repo.txnsBetween(now.subtract(const Duration(days: bankHistoryDays)), now.add(const Duration(days: 1)));
    for (final t in txns.where((t) => t.ownTransfer)) {
      await _learnMyName(t);
    }
    var n = 0;
    // Twice: a pair found late in the first pass may teach my name to operations before it.
    for (var pass = 0; pass < 2; pass++) {
      for (final t in txns) {
        // Earlier iterations may have paired this one already.
        final fresh = await repo.txnById(t.id!);
        if (fresh != null && !fresh.ownTransfer && await _ownTransfer(fresh)) n++;
      }
    }
    return n;
  }

  /// For operations added from elsewhere (a bank statement): pairs a transfer to myself.
  Future<bool> checkOwnTransfer(Txn t) => _ownTransfer(t);

  /// "Перевод между своими счетами", "перевод себе" in the bank's text.
  static final _toMyself = RegExp(
    r'между\s+(своими\s+)?сч[её]тами|перевод\s+себе|на\s+сво[йи]\s+сч[её]т|со\s+своего\s+сч[её]та|'
    r'own\s+accounts?|to\s+myself|өз\s+шоттар',
    caseSensitive: false,
  );

  /// A bank operation is a transfer to myself when the other side (another of my banks, opposite
  /// direction, same amount) was recorded too, when the bank says so, or when it goes to / comes
  /// from my own name as learned from earlier pairs.
  Future<bool> _ownTransfer(Txn t) async {
    if (t.ownTransfer) return true;
    if (t.excluded || !Repository.isBankSource(t.source)) return false;
    final twin = await repo.findTransferTwin(t);
    if (twin != null) {
      await repo.linkOwnTransfer(t, twin);
      await _learnMyName(t);
      await _learnMyName(twin);
      return true;
    }
    final self = await repo.selfNames();
    final names = {
      if (t.merchant != null) Repository.normalizeName(t.merchant!),
      ?Repository.senderIn(t.raw),
    };
    if (_toMyself.hasMatch(t.raw ?? '') || names.any(self.contains)) {
      await repo.linkOwnTransfer(t, null);
      return true;
    }
    return false;
  }

  /// How the banks name me, from a confirmed transfer to myself: the payee or the sender in the text.
  Future<void> _learnMyName(Txn t) async {
    await repo.addSelfName(t.merchant);
    await repo.addSelfName(Repository.senderIn(t.raw));
  }

  /// A row of Alipay's Bills list: confirms an already recorded payment (filling in the merchant)
  /// or adds one we missed (auto-debits like bike rides). Days already covered by the Excel
  /// import are skipped, so history is not counted twice.
  Future<bool> _importBillRow(CapturedPayment p, List<Category> categories, DateTime? excelUntil, int? accountId) async {
    final day = DateTime(p.time.year, p.time.month, p.time.day);
    if (excelUntil != null && !day.isAfter(excelUntil)) return false;

    final existing = await repo.findSamePayment(
      appPrefix: p.app,
      kind: p.kind,
      amountMinor: p.amountMinor,
      time: p.time,
    );
    Future<int?> category(String? merchant) async {
      if (merchant != null) {
        final learned = await repo.categoryForMerchant(merchant, p.kind);
        if (learned != null) return learned;
      }
      final key = alipayCategoryKey(p.category, p.kind);
      return categories.where((c) => c.kind == p.kind && c.key != null && c.key == key).firstOrNull?.id;
    }

    if (existing != null) {
      if (existing.source.contains('bill')) return false;
      final merchant = existing.merchant ?? p.merchant;
      final categoryId = existing.categoryId ?? await category(merchant);
      await repo.updateTxn(existing.copyWith(
        merchant: () => merchant,
        categoryId: () => categoryId,
        source: existing.source == 'manual' ? 'manual' : '${existing.source}+bill',
        needsReview: existing.needsReview && categoryId == null,
      ));
      return false;
    }
    // Deleted by the user earlier: don't bring it back.
    final deleted = await repo.dismissedCount(
      app: p.app,
      kind: p.kind,
      amountMinor: p.amountMinor,
      from: p.time.subtract(const Duration(minutes: 3)),
      to: p.time.add(const Duration(minutes: 3)),
    );
    if (deleted > 0) return false;

    final categoryId = await category(p.merchant);
    await repo.insertTxn(Txn(
      time: p.time,
      amountMinor: p.amountMinor,
      currency: p.currency,
      kind: p.kind,
      categoryId: categoryId,
      accountId: accountId,
      merchant: p.merchant,
      note: p.method,
      source: '${p.app}:bill',
      needsReview: categoryId == null,
      raw: p.raw,
    ));
    return true;
  }

  /// A row of a bank app's operations history (see BankHistory.kt). Rows may have only a date and
  /// the same amount may appear twice a day, so they are counted per day: row number n (0-based,
  /// "bank_history|n|…") needs at least n+1 such operations of that day, counting deleted ones.
  Future<bool> _importBankRow(
      CapturedPayment p, List<Category> categories, DateTime? excelUntil, Future<int?> Function() account) async {
    final day = DateTime(p.time.year, p.time.month, p.time.day);
    if (excelUntil != null && !day.isAfter(excelUntil)) return false;
    // Old history (scrolled far back) predates the app: the opening balance already includes it.
    if (DateTime.now().difference(day).inDays > bankHistoryDays) return false;

    final n = int.tryParse(p.raw.split('|').elementAtOrNull(1) ?? '') ?? 0;
    final existing = await repo.sameDayPayments(
        app: p.app, kind: p.kind, amountMinor: p.amountMinor, currency: p.currency, day: day);
    final deleted = await repo.dismissedCount(
        app: p.app, kind: p.kind, amountMinor: p.amountMinor, from: day, to: DateTime(day.year, day.month, day.day + 1));

    Future<int?> category(String? merchant) async {
      if (merchant != null) {
        final learned = await repo.categoryForMerchant(merchant, p.kind);
        if (learned != null) return learned;
      }
      final key = bankCategoryKey(p.category, p.kind);
      return categories.where((c) => c.kind == p.kind && c.key != null && c.key == key).firstOrNull?.id;
    }

    if (existing.length + deleted > n) {
      // Already known: confirm one that the history hasn't confirmed yet, filling in the merchant.
      final t = existing.where((t) => !t.source.contains('bill')).firstOrNull;
      if (t == null) return false;
      final merchant = t.merchant ?? p.merchant;
      final categoryId = t.categoryId ?? await category(merchant);
      await repo.updateTxn(t.copyWith(
        merchant: () => merchant,
        categoryId: () => categoryId,
        source: t.source == 'manual' ? 'manual' : '${t.source}+bill',
        needsReview: t.needsReview && categoryId == null,
      ));
      return false;
    }

    final categoryId = await category(p.merchant);
    final id = await repo.insertTxn(Txn(
      time: p.time,
      amountMinor: p.amountMinor,
      currency: p.currency,
      kind: p.kind,
      categoryId: categoryId,
      accountId: await account(),
      merchant: p.merchant,
      source: '${p.app}:bill',
      needsReview: categoryId == null,
      raw: p.raw,
    ));
    await _settle(id);
    return true;
  }

  /// A Google Wallet payment turns out to be this bank's card payment: it moves to the bank's
  /// account and source, keeping the Wallet's time and shop name (usually the cleaner one).
  Future<void> _adoptWalletPayment(Txn t, CapturedPayment p, int? accountId) async {
    final merchant = t.merchant ?? p.merchant;
    final categoryId = t.categoryId ?? (merchant == null ? null : await repo.categoryForMerchant(merchant, t.kind));
    await repo.updateTxn(t.copyWith(
      accountId: () => t.accountId ?? accountId,
      merchant: () => merchant,
      categoryId: () => categoryId,
      source: '${p.app}:${p.source}+wallet',
      needsReview: categoryId == null,
    ));
    await _settle(t.id!);
  }

  /// The same bank's history row of that day for a notification that came later.
  Future<Txn?> _historyTwin(CapturedPayment p) async {
    final same = await repo.sameDayPayments(
        app: p.app, kind: p.kind, amountMinor: p.amountMinor, currency: p.currency, day: p.time);
    return same.where((t) => t.source == '${p.app}:bill').firstOrNull;
  }

  Future<Txn> _merge(Txn t, CapturedPayment p) async {
    final merchant = t.merchant ?? p.merchant;
    var categoryId = t.categoryId;
    if (categoryId == null && merchant != null) categoryId = await repo.categoryForMerchant(merchant, t.kind);
    // The screen is seen at the moment of payment; prefer its time. Bank history rows often
    // have only a date, so a notification's time is better.
    final time = p.source == 'screen' || t.source.endsWith(':bill') ? p.time : t.time;
    return t.copyWith(
      time: time,
      merchant: () => merchant,
      note: () => t.note ?? p.method,
      categoryId: () => categoryId,
      source: '${t.source}+${p.source}',
      needsReview: categoryId == null,
      // Kept so a re-posted notification is recognized (see isRepeatedNotification).
      raw: p.source == 'notification' && p.raw.isNotEmpty && !(t.raw ?? '').contains(p.raw) ? '${t.raw ?? ''}\n${p.raw}' : null,
    );
  }
}
