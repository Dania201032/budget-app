part of 'overview_screen.dart';

/// "By day" in three forms: a phone-friendly list (default), a calendar heatmap, and the
/// spreadsheet-like table. The choice is remembered.
class _BreakdownViews extends StatelessWidget {
  final AppState state;
  const _BreakdownViews({required this.state});

  @override
  Widget build(BuildContext context) {
    final view = state.overviewView;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
        child: SegmentedButton<String>(
          showSelectedIcon: false,
          segments: [
            ButtonSegment(value: 'list', icon: const Icon(Icons.view_agenda_outlined), label: segmentLabel(tr('view_list'))),
            ButtonSegment(value: 'calendar', icon: const Icon(Icons.calendar_month_outlined), label: segmentLabel(tr('view_calendar'))),
            ButtonSegment(value: 'table', icon: const Icon(Icons.table_chart_outlined), label: segmentLabel(tr('view_table'))),
          ],
          selected: {view},
          onSelectionChanged: (s) => state.setOverviewView(s.first),
        ),
      ),
      switch (view) {
        'calendar' => PeriodCalendar(state: state, stats: state.periodStats!, txns: state.periodTxns),
        'table' => _BreakdownGrid(state: state),
        _ => _DayList(state: state),
      },
    ]);
  }
}

/// Per-bucket figures shared by the list and the calendar.
class _Bucket {
  final DateTime start;
  final int spent;
  final int limit;
  final int? left; // null for buckets that haven't started
  final int? running;
  final List<(int?, int)> byCategory; // (category id, amount), largest first
  const _Bucket(this.start, this.spent, this.limit, this.left, this.running, this.byCategory);
}

List<_Bucket> _buckets(PeriodStats stats) {
  final now = DateTime.now();
  final out = <_Bucket>[];
  var acc = 0;
  for (var i = 0; i < stats.period.buckets.length; i++) {
    final b = stats.period.buckets[i];
    final started = !b.isAfter(now);
    final left = stats.budgetByBucket[i] - stats.spentByBucket[i];
    if (started) acc += left;
    final cats = <(int?, int)>[
      for (final e in stats.grid.entries)
        if (e.value[i] > 0) (e.key, e.value[i]),
    ]..sort((a, b) => b.$2.compareTo(a.$2));
    out.add(_Bucket(b, stats.spentByBucket[i], stats.budgetByBucket[i], started ? left : null, started ? acc : null, cats));
  }
  return out;
}

Color _catColor(AppState state, int? id, BuildContext context) =>
    id == null || state.categoryById[id] == null ? Theme.of(context).colorScheme.outline : Color(state.categoryById[id]!.color);

String _catName(AppState state, int? id) =>
    id == null || state.categoryById[id] == null ? tr('no_category') : state.categoryName(state.categoryById[id]!);

/// List: one row per day (or month for a year) with a stacked category bar and the limit mark.
class _DayList extends StatefulWidget {
  final AppState state;
  const _DayList({required this.state});

  @override
  State<_DayList> createState() => _DayListState();
}

class _DayListState extends State<_DayList> {
  final Set<DateTime> _open = {};

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    final stats = state.periodStats!;
    final period = stats.period;
    final theme = Theme.of(context);
    final cur = state.baseCurrency;
    final budgetOn = state.budgetEnabled;
    final buckets = _buckets(stats);
    final isYear = period.type == PeriodType.year;
    final scale = math.max(1, buckets.fold<int>(0, (m, b) => math.max(m, math.max(b.spent, budgetOn ? b.limit : 0))));
    final now = DateTime.now();
    Color sign(int v) => Ledger.signOf(context, v);

    String label(DateTime d) => isYear
        ? toBeginningOfSentenceCase(DateFormat.LLLL(intlLocale).format(d))
        : '${toBeginningOfSentenceCase(DateFormat.E(intlLocale).format(d))}, ${DateFormat.MMMd(intlLocale).format(d)}';

    return Column(children: [
      for (final b in buckets)
        Opacity(
          opacity: b.start.isAfter(now) ? 0.45 : 1,
          child: InkWell(
            onTap: () => setState(() => _open.contains(b.start) ? _open.remove(b.start) : _open.add(b.start)),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Expanded(child: Text(label(b.start), style: theme.textTheme.bodyMedium)),
                  Text(formatMoney(b.spent, cur), style: mono(size: 14)),
                ]),
                const SizedBox(height: 4),
                LayoutBuilder(builder: (context, c) {
                  final w = c.maxWidth;
                  return SizedBox(
                    height: 10,
                    child: Stack(clipBehavior: Clip.none, children: [
                      Container(
                        width: w,
                        decoration: BoxDecoration(
                          color: theme.colorScheme.surfaceContainerHighest,
                          ),
                      ),
                      ClipRect(
                        child: Row(children: [
                          for (final (id, amount) in b.byCategory)
                            Container(
                              width: math.max(2, w * amount / scale - 2),
                              margin: const EdgeInsets.only(right: 2),
                              color: _catColor(state, id, context),
                            ),
                        ]),
                      ),
                      if (budgetOn && b.limit > 0)
                        Positioned(
                          left: (w * b.limit / scale).clamp(0, w - 2).toDouble(),
                          top: -3,
                          child: Container(width: 2, height: 16, color: theme.colorScheme.onSurface),
                        ),
                    ]),
                  );
                }),
                if (budgetOn && b.left != null) ...[
                  const SizedBox(height: 4),
                  // Wraps onto a second line on narrow phones / long translations.
                  Wrap(spacing: 16, runSpacing: 2, children: [
                    Text.rich(TextSpan(style: theme.textTheme.bodySmall, children: [
                      TextSpan(text: '${tr(isYear ? 'grid_month_left' : 'grid_day_left')} '),
                      TextSpan(
                        text: formatMoney(b.left!, cur, signed: true),
                        style: TextStyle(color: sign(b.left!), fontWeight: FontWeight.w600),
                      ),
                    ])),
                    Text.rich(TextSpan(style: theme.textTheme.bodySmall, children: [
                      TextSpan(text: '${tr('grid_running')} '),
                      TextSpan(text: formatMoney(b.running!, cur, signed: true), style: TextStyle(color: sign(b.running!))),
                    ])),
                  ]),
                ],
                if (_open.contains(b.start)) _DayDetails(state: state, bucket: b, isYear: isYear, source: state.periodTxns),
              ]),
            ),
          ),
        ),
      if (budgetOn)
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
          child: Row(children: [
            Container(width: 2, height: 12, color: theme.colorScheme.onSurface),
            const SizedBox(width: 6),
            Text(tr(isYear ? 'grid_budget' : 'grid_limit'), style: theme.textTheme.bodySmall),
            const SizedBox(width: 16),
            Expanded(child: Text(tr('tap_day_hint'), style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.outline))),
          ]),
        ),
    ]);
  }
}

/// Categories of a day (and its transactions for day buckets).
class _DayDetails extends StatelessWidget {
  final AppState state;
  final _Bucket bucket;
  final bool isYear;
  final List<Txn> source;
  const _DayDetails({required this.state, required this.bucket, required this.isYear, required this.source});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cur = state.baseCurrency;
    final txns = isYear
        ? const <Txn>[]
        : source
            .where((t) =>
                t.time.year == bucket.start.year && t.time.month == bucket.start.month && t.time.day == bucket.start.day)
            .toList();
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        for (final (id, amount) in bucket.byCategory)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Row(children: [
              Container(width: 8, height: 8, color: _catColor(state, id, context)),
              const SizedBox(width: 8),
              Expanded(child: Text(_catName(state, id), style: theme.textTheme.bodySmall)),
              Text(formatMoney(amount, cur), style: mono(size: 12, weight: FontWeight.w400)),
            ]),
          ),
        for (final t in txns) TxnTile(t, onTap: () => openTxnEditor(context, txn: t)),
      ]),
    );
  }
}

/// Month (or week / year) as a sheet of cells: mint = within the limit, yellow = over it,
/// the current day outlined. Tap a cell for its categories and transactions.
class PeriodCalendar extends StatelessWidget {
  final AppState state;
  final PeriodStats stats;
  final List<Txn> txns;
  final bool showHint;
  const PeriodCalendar({super.key, required this.state, required this.stats, required this.txns, this.showHint = true});

  @override
  Widget build(BuildContext context) {
    final period = stats.period;
    final theme = Theme.of(context);
    final buckets = _buckets(stats);
    final isYear = period.type == PeriodType.year;
    final accent = Ledger.accentOf(context);
    final muted = Ledger.mutedOf(context);
    final maxSpent = math.max(1, buckets.fold<int>(0, (m, b) => math.max(m, b.spent)));
    final budgetOn = state.budgetEnabled;
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);

    Widget cell(_Bucket b, String title) {
      final future = b.start.isAfter(now);
      final current = isYear ? (b.start.year == now.year && b.start.month == now.month) : b.start == today;
      final over = budgetOn && b.limit > 0 && b.spent > b.limit;
      final Color bg;
      if (future || (b.spent == 0 && !budgetOn)) {
        bg = theme.colorScheme.surface;
      } else if (budgetOn && b.limit > 0) {
        bg = over ? Ledger.overOf(context) : Ledger.withinOf(context);
      } else {
        bg = accent.withValues(alpha: 0.08 + 0.4 * (b.spent / maxSpent));
      }
      return GestureDetector(
        onTap: () => showModalBottomSheet(
          context: context,
          showDragHandle: true,
          builder: (_) => SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(isYear ? toBeginningOfSentenceCase(DateFormat.yMMMM(intlLocale).format(b.start)) : dayHeader(b.start),
                    style: theme.textTheme.titleMedium),
                Text(formatMoney(b.spent, state.baseCurrency), style: mono(size: 26)),
                if (budgetOn && b.left != null)
                  Text('${tr(isYear ? 'grid_month_left' : 'grid_day_left')}: ${formatMoney(b.left!, state.baseCurrency, signed: true)}',
                      style: mono(size: 13, color: Ledger.signOf(context, b.left!))),
                _DayDetails(state: state, bucket: b, isYear: isYear, source: txns),
              ]),
            ),
          ),
        ),
        child: Container(
          decoration: BoxDecoration(
            color: bg,
            border: current ? Border.all(color: accent, width: 2) : null,
          ),
          padding: const EdgeInsets.fromLTRB(4, 3, 4, 3),
          // Stack, not Column: small cells must never overflow with large system font sizes.
          child: Stack(children: [
            Align(
              alignment: Alignment.topLeft,
              child: Text(title, maxLines: 1, style: mono(size: 9.5, weight: FontWeight.w400, color: muted)),
            ),
            if (b.spent > 0 && !future)
              Align(
                alignment: Alignment.bottomRight,
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(NumberFormat.compact(locale: intlLocale).format(b.spent / 100), style: mono(size: 11.5)),
                ),
              ),
          ]),
        ),
      );
    }

    Widget sheet({required int columns, required double aspect, required List<Widget> cells}) => Container(
          color: Ledger.ruleOf(context),
          padding: const EdgeInsets.all(1),
          child: GridView.count(
            crossAxisCount: columns,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            mainAxisSpacing: 1,
            crossAxisSpacing: 1,
            childAspectRatio: aspect,
            padding: EdgeInsets.zero,
            children: cells,
          ),
        );

    if (isYear) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: sheet(
          columns: 4,
          aspect: 1.5,
          cells: [for (final b in buckets) cell(b, DateFormat.LLL(intlLocale).format(b.start))],
        ),
      );
    }

    // Week rows starting on Monday; shaded cells before the 1st of the month.
    final lead = buckets.isEmpty ? 0 : buckets.first.start.weekday - 1;
    final trail = (7 - (lead + buckets.length) % 7) % 7;
    final weekdays = [for (var i = 0; i < 7; i++) DateFormat.E(intlLocale).format(DateTime(2024, 1, 1 + i))]; // 2024-01-01 is a Monday
    final blank = ColoredBox(color: Ledger.shadeOf(context));
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          for (final w in weekdays) Expanded(child: Center(child: Text(w, style: mono(size: 10, weight: FontWeight.w400, color: muted)))),
        ]),
        const SizedBox(height: 4),
        sheet(
          columns: 7,
          aspect: 1.15,
          cells: [
            for (var i = 0; i < lead; i++) blank,
            for (final b in buckets) cell(b, '${b.start.day}'),
            for (var i = 0; i < trail; i++) blank,
          ],
        ),
        if (budgetOn && showHint)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(tr('calendar_hint'), style: theme.textTheme.bodySmall?.copyWith(color: muted)),
          ),
      ]),
    );
  }
}
