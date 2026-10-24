import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollDirection;
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../data/models.dart';
import '../domain/money.dart';
import '../domain/periods.dart';
import '../household/household.dart' show personColors;
import '../l10n/strings.dart';
import '../state/app_state.dart';
import 'ledger.dart';
import 'motion.dart';

/// Category icons are stored by name: constructing IconData from stored code points
/// would break icon tree-shaking in release builds.
const categoryIcons = <String, IconData>{
  'restaurant': Icons.restaurant,
  'local_cafe': Icons.local_cafe,
  'directions_bus': Icons.directions_bus,
  'celebration': Icons.celebration,
  'shopping_bag': Icons.shopping_bag,
  'home': Icons.home,
  'wifi': Icons.wifi,
  'favorite': Icons.favorite,
  'school': Icons.school,
  'more_horiz': Icons.more_horiz,
  'work': Icons.work,
  'swap_horiz': Icons.swap_horiz,
  'flight': Icons.flight,
  'fitness_center': Icons.fitness_center,
  'pets': Icons.pets,
  'card_giftcard': Icons.card_giftcard,
  'local_grocery_store': Icons.local_grocery_store,
  'checkroom': Icons.checkroom,
  'savings': Icons.savings,
  'sports_esports': Icons.sports_esports,
  'local_bar': Icons.local_bar,
  'fastfood': Icons.fastfood,
  'icecream': Icons.icecream,
  'bakery_dining': Icons.bakery_dining,
  'local_taxi': Icons.local_taxi,
  'train': Icons.train,
  'directions_car': Icons.directions_car,
  'local_gas_station': Icons.local_gas_station,
  'pedal_bike': Icons.pedal_bike,
  'hotel': Icons.hotel,
  'luggage': Icons.luggage,
  'movie': Icons.movie,
  'music_note': Icons.music_note,
  'menu_book': Icons.menu_book,
  'phone_iphone': Icons.phone_iphone,
  'computer': Icons.computer,
  'subscriptions': Icons.subscriptions,
  'local_laundry_service': Icons.local_laundry_service,
  'content_cut': Icons.content_cut,
  'spa': Icons.spa,
  'medication': Icons.medication,
  'local_hospital': Icons.local_hospital,
  'child_care': Icons.child_care,
  'redeem': Icons.redeem,
  'volunteer_activism': Icons.volunteer_activism,
  'receipt_long': Icons.receipt_long,
  'account_balance': Icons.account_balance,
  'payments': Icons.payments,
  'trending_up': Icons.trending_up,
  'print': Icons.print,
  'water_drop': Icons.water_drop,
  'bolt': Icons.bolt,
  'build': Icons.build,
  'label': Icons.label,
};

/// Ledger palette: muted mid-tones that read on both paper and the dark page.
const categoryColors = <int>[
  0xFF2F7A66, 0xFF8C6A4A, 0xFF4A6FA5, 0xFF9A5B8C, 0xFFC98A1E, 0xFF5E7F3A,
  0xFF3E8E9E, 0xFFB5524A, 0xFF6A64A8, 0xFF8A8880, 0xFF4F9E86, 0xFFA0703C,
  0xFF7A8F3C, 0xFFC2667A, 0xFF5B87A8, 0xFF0E5E52,
];

/// Name + icon + color editor; returns null when cancelled.
Future<(String, String, int)?> showCategoryDialog(
  BuildContext context, {
  required String title,
  String name = '',
  String icon = 'label',
  int? color,
}) {
  return showDialog<(String, String, int)>(
    context: context,
    builder: (_) => _CategoryDialog(title: title, name: name, icon: icon, color: color ?? categoryColors.first),
  );
}

class _CategoryDialog extends StatefulWidget {
  final String title;
  final String name;
  final String icon;
  final int color;
  const _CategoryDialog({required this.title, required this.name, required this.icon, required this.color});

  @override
  State<_CategoryDialog> createState() => _CategoryDialogState();
}

class _CategoryDialogState extends State<_CategoryDialog> {
  late final TextEditingController _name = TextEditingController(text: widget.name);
  late String _icon = widget.icon;
  late int _color = widget.color;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 360,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            TextField(
              controller: _name,
              autofocus: widget.name.isEmpty,
              textCapitalization: TextCapitalization.sentences,
              decoration: InputDecoration(labelText: tr('name')),
            ),
            const SizedBox(height: 16),
            Text(tr('color')),
            const SizedBox(height: 8),
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (final c in categoryColors)
                GestureDetector(
                  onTap: () => setState(() => _color = c),
                  child: Container(
                    width: 30,
                    height: 30,
                    decoration: BoxDecoration(
                      color: Color(c),
                      shape: BoxShape.circle,
                      border: Border.all(color: c == _color ? scheme.onSurface : Colors.transparent, width: 2.5),
                    ),
                  ),
                ),
            ]),
            const SizedBox(height: 16),
            Text(tr('icon')),
            const SizedBox(height: 8),
            Wrap(spacing: 4, runSpacing: 4, children: [
              for (final e in categoryIcons.entries)
                InkWell(
                  borderRadius: BorderRadius.circular(20),
                  onTap: () => setState(() => _icon = e.key),
                  child: Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: e.key == _icon ? Color(_color).withValues(alpha: 0.2) : null,
                    ),
                    child: Icon(e.value, color: e.key == _icon ? Color(_color) : scheme.onSurfaceVariant),
                  ),
                ),
            ]),
          ]),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(tr('cancel'))),
        FilledButton(
          onPressed: () {
            final n = _name.text.trim();
            if (n.isEmpty) return;
            Navigator.pop(context, (n, _icon, _color));
          },
          child: Text(tr('save')),
        ),
      ],
    );
  }
}

/// Horizontal swipe → previous / next period. Vertical scrolling inside still works.
class SwipeToChange extends StatelessWidget {
  final Widget child;
  final VoidCallback onPrevious;
  final VoidCallback onNext;
  const SwipeToChange({super.key, required this.child, required this.onPrevious, required this.onNext});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onHorizontalDragEnd: (d) {
        final v = d.primaryVelocity ?? 0;
        if (v > 300) onPrevious();
        if (v < -300) onNext();
      },
      child: child,
    );
  }
}

/// "‹ October 2026 ›" for an app bar.
class PeriodSwitcher extends StatelessWidget {
  final Period period;
  final ValueChanged<Period> onChanged;
  const PeriodSwitcher({super.key, required this.period, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final localizations = MaterialLocalizations.of(context);
    Widget square(IconData icon, String tooltip, int step) => SizedBox(
          width: 40,
          height: 40,
          child: OutlinedButton(
            style: OutlinedButton.styleFrom(padding: EdgeInsets.zero),
            onPressed: () => onChanged(period.shift(step)),
            child: Tooltip(message: tooltip, child: Icon(icon, size: 20)),
          ),
        );
    return Row(children: [
      Expanded(
        child: Text(period.label(), style: Theme.of(context).textTheme.titleLarge, overflow: TextOverflow.ellipsis),
      ),
      square(Icons.chevron_left, localizations.previousPageTooltip, -1),
      const SizedBox(width: 6),
      square(Icons.chevron_right, localizations.nextPageTooltip, 1),
    ]);
  }
}

/// Day / Week / Month / Year as underlined text tabs (for an app bar bottom or a page).
class PeriodTabs extends StatelessWidget {
  final PeriodType selected;
  final ValueChanged<PeriodType> onChanged;
  const PeriodTabs({super.key, required this.selected, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final ink = Ledger.inkOf(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(children: [
        for (final t in PeriodType.values)
          InkWell(
            onTap: () => onChanged(t),
            child: Container(
              height: 44,
              margin: const EdgeInsets.only(right: 22),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                border: Border(
                  bottom: BorderSide(color: t == selected ? Ledger.accentOf(context) : Colors.transparent, width: 3),
                ),
              ),
              child: Text(
                t.label,
                style: mono(
                  size: 13,
                  weight: t == selected ? FontWeight.w600 : FontWeight.w400,
                  color: t == selected ? ink : Ledger.mutedOf(context),
                ),
              ),
            ),
          ),
      ]),
    );
  }
}

/// Day / Week / Month / Year selector for an app bar bottom.
PreferredSizeWidget periodTypeBar(PeriodType selected, ValueChanged<PeriodType> onChanged) => PreferredSize(
      preferredSize: const Size.fromHeight(44),
      child: PeriodTabs(selected: selected, onChanged: onChanged),
    );

class CategoryAvatar extends StatelessWidget {
  final Category? category;
  final double size;
  const CategoryAvatar(this.category, {super.key, this.size = 40});

  @override
  Widget build(BuildContext context) {
    final c = category;
    final color = c == null ? Theme.of(context).colorScheme.outline : Color(c.color);
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(color: color.withValues(alpha: 0.16), borderRadius: BorderRadius.circular(3)),
      child: Icon(c == null ? Icons.help_outline : categoryIcons[c.icon] ?? Icons.label, color: color, size: size * 0.55),
    );
  }
}

class TxnTile extends StatelessWidget {
  final Txn txn;
  final VoidCallback? onTap;
  const TxnTile(this.txn, {super.key, this.onTap});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final cat = txn.categoryId == null ? null : state.categoryById[txn.categoryId];
    final account = txn.accountId == null ? null : state.accountById[txn.accountId];
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final isIncome = txn.kind == TxnKind.income;

    final title = cat != null ? state.categoryName(cat) : (txn.merchant ?? tr('no_category'));
    final subtitleParts = [
      if (cat != null && txn.merchant != null) txn.merchant!,
      if (txn.note != null && txn.note!.isNotEmpty && txn.source == 'manual') txn.note!,
      if (account != null) state.accountName(account),
      DateFormat.Hm(intlLocale).format(txn.time),
    ];
    final small = theme.textTheme.bodySmall?.copyWith(color: scheme.outline);

    final tile = ListTile(
      onTap: onTap,
      contentPadding: const EdgeInsets.symmetric(horizontal: 4),
      leading: CategoryAvatar(cat, size: 36),
      title: Row(children: [
        Flexible(child: Text(title, overflow: TextOverflow.ellipsis)),
        if (txn.isCaptured) ...[
          const SizedBox(width: 6),
          Icon(Icons.bolt, size: 16, color: scheme.primary),
        ],
        if (txn.isSplit) ...[
          const SizedBox(width: 4),
          Icon(Icons.call_split, size: 16, color: scheme.tertiary),
        ],
        if (txn.ownTransfer) ...[
          const SizedBox(width: 4),
          Icon(Icons.swap_horiz, size: 16, color: scheme.outline),
        ],
        // Shared budget: who recorded it, when it wasn't me.
        if (state.householdOn && txn.author != null && txn.author != state.me && state.personOf(txn.author) != null) ...[
          const SizedBox(width: 6),
          PersonBadge(state.personOf(txn.author)!, size: 16),
        ],
      ]),
      subtitle: Text(subtitleParts.join(' · '), maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text(
            txn.amountMinor == 0
                ? tr('amount_unknown')
                : formatMoney(isIncome ? txn.amountMinor : -txn.amountMinor, txn.currency, signed: true),
            style: mono(
              size: 15,
              color: txn.excluded ? scheme.outline : (isIncome ? Ledger.goodOf(context) : null),
            ).copyWith(decoration: txn.excluded && txn.source != 'goal' && !txn.ownTransfer ? TextDecoration.lineThrough : null),
          ),
          if (txn.source == 'goal')
            Text(tr('goal_transfer', [txn.merchant ?? '']), style: small)
          else if (txn.ownTransfer)
            Text(tr('own_transfer_short'), style: small)
          else if (txn.excluded)
            Text(tr('debt_repaid'), style: small)
          else if (txn.isSplit)
            Text(tr('my_share', [formatMoney(txn.shareMinor!, txn.currency)]), style: small)
          else if (txn.currency != state.baseCurrency)
            Text(
              switch (state.toBase(txn)) {
                null => tr('no_rate'),
                final v => '≈ ${formatMoney(v, state.baseCurrency)}',
              },
              style: small,
            ),
        ],
      ),
    );
    return AppearIn(
      animate: state.isFresh(txn),
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(border: Border(bottom: BorderSide(color: Ledger.ruleOf(context)))),
        child: tile,
      ),
    );
  }
}

String dayHeader(DateTime d) {
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(d.year, d.month, d.day);
  if (day == today) return tr('today');
  if (day == today.subtract(const Duration(days: 1))) return tr('yesterday');
  final s = (d.year == now.year ? DateFormat.MMMMEEEEd(intlLocale) : DateFormat.yMMMMEEEEd(intlLocale)).format(d);
  return s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);
}

/// Simple amount input dialog; returns minor units or null.
Future<int?> askAmount(BuildContext context, {required String title, String? subtitle, String? initial, String? suffix}) {
  final controller = TextEditingController(text: initial ?? '');
  return showDialog<int>(
    context: context,
    builder: (c) => AlertDialog(
      title: Text(title),
      content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (subtitle != null) Padding(padding: const EdgeInsets.only(bottom: 8), child: Text(subtitle)),
        TextField(
          controller: controller,
          autofocus: true,
          keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
          decoration: InputDecoration(suffixText: suffix),
        ),
      ]),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c), child: Text(tr('cancel'))),
        FilledButton(
          onPressed: () {
            final text = controller.text.trim();
            final negative = text.startsWith('-') || text.startsWith('−');
            final v = parseAmountToMinor(text.replaceFirst(RegExp(r'^[-−]'), ''));
            if (v != null) Navigator.pop(c, negative ? -v : v);
          },
          child: Text(tr('save')),
        ),
      ],
    ),
  );
}

/// A floating button that slides away while the list under it scrolls down (it would sit over rows
/// and their buttons) and comes back when the list scrolls up. Wrap the screen's body with
/// [hideFabOnScroll] using the same [visible] notifier.
class ScrollAwareFab extends StatelessWidget {
  final ValueNotifier<bool> visible;
  final Widget child;
  const ScrollAwareFab({super.key, required this.visible, required this.child});

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<bool>(
        valueListenable: visible,
        builder: (_, shown, child) => AnimatedSlide(
          offset: shown ? Offset.zero : const Offset(0, 2),
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
          child: IgnorePointer(ignoring: !shown, child: child),
        ),
        child: child,
      );
}

Widget hideFabOnScroll(ValueNotifier<bool> visible, Widget body) => NotificationListener<UserScrollNotification>(
      onNotification: (n) {
        // Only the screen's own list, not nested horizontal ones.
        if (n.metrics.axis == Axis.vertical) {
          if (n.direction == ScrollDirection.reverse) visible.value = false;
          if (n.direction == ScrollDirection.forward) visible.value = true;
        }
        return false;
      },
      child: body,
    );

/// A person's initial in their color, next to operations and accounts in a shared budget.
class PersonBadge extends StatelessWidget {
  final Person person;
  final double size;
  const PersonBadge(this.person, {super.key, this.size = 18});

  @override
  Widget build(BuildContext context) => Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: BoxDecoration(color: Color(person.color == 0 ? personColors.first : person.color), shape: BoxShape.circle),
        child: Text(person.initial,
            style: TextStyle(color: Colors.white, fontSize: size * 0.55, fontWeight: FontWeight.w600, height: 1)),
      );
}

