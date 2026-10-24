import 'package:flutter/material.dart';

import '../data/models.dart';
import '../domain/money.dart';
import '../l10n/strings.dart';
import '../state/app_state.dart';

/// "Close a goal" for a purchase: which goal paid for it, and whether the goal is reached
/// (closed) or only this amount was taken from its savings. Null when cancelled.
Future<(Goal, bool)?> chooseGoalSpend(BuildContext context, AppState state) async {
  final goals = state.goals;
  if (goals.isEmpty) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('goal_none'))));
    return null;
  }
  final goal = goals.length == 1
      ? goals.single
      : await showDialog<Goal>(
          context: context,
          builder: (ctx) => SimpleDialog(
            title: Text(tr('goal_which')),
            children: [
              for (final g in goals)
                SimpleDialogOption(
                  onPressed: () => Navigator.pop(ctx, g),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(g.name, style: Theme.of(ctx).textTheme.bodyLarge),
                    Text(
                      tr('goal_saved_of', [formatMoney(g.savedMinor, g.currency), formatMoney(g.targetMinor, g.currency)]),
                      style: Theme.of(ctx).textTheme.bodySmall,
                    ),
                  ]),
                ),
            ],
          ),
        );
  if (goal == null || !context.mounted) return null;
  final close = await showDialog<bool>(
    context: context,
    builder: (ctx) => SimpleDialog(
      title: Text(goal.name),
      children: [
        SimpleDialogOption(
          onPressed: () => Navigator.pop(ctx, true),
          child: ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.flag),
            title: Text(tr('goal_close_full')),
            subtitle: Text(tr('goal_close_full_sub')),
          ),
        ),
        SimpleDialogOption(
          onPressed: () => Navigator.pop(ctx, false),
          child: ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.outlined_flag),
            title: Text(tr('goal_close_part')),
            subtitle: Text(tr('goal_close_part_sub')),
          ),
        ),
      ],
    ),
  );
  return close == null ? null : (goal, close);
}
