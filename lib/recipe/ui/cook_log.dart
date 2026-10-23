import 'package:flutter/material.dart';

import '../recipe_store.dart';

/// "17 Oct 2026" — local time, since it is the user's own cook or edit.
String formatDay(DateTime date) {
  const months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  final local = date.toLocal();
  return '${local.day} ${months[local.month - 1]} ${local.year}';
}

/// Five stars, [stars] of them filled, read-only.
class StarsRow extends StatelessWidget {
  final int stars;
  final Color accent;
  final double? size;

  const StarsRow({
    super.key,
    required this.stars,
    required this.accent,
    this.size,
  });

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      for (var star = 1; star <= 5; star++)
        Icon(
          star <= stars ? Icons.star : Icons.star_border,
          size: size,
          color: star <= stars ? accent : null,
        ),
    ],
  );
}

/// One cook: when, for how many, how it went, and the note. Tappable when
/// [onTap] is given — the detail screen edits through it, history only reads.
class CookEntryLine extends StatelessWidget {
  final CookEntry entry;
  final Color accent;
  final VoidCallback? onTap;

  const CookEntryLine({
    super.key,
    required this.entry,
    required this.accent,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final servings = entry.servings;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    servings == null
                        ? formatDay(entry.date)
                        : '${formatDay(entry.date)} · for $servings',
                    style: theme.textTheme.bodySmall,
                  ),
                ),
                if (entry.stars > 0)
                  StarsRow(stars: entry.stars, accent: accent, size: 16),
              ],
            ),
            if (entry.note.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(entry.note, style: theme.textTheme.bodyMedium),
              ),
          ],
        ),
      ),
    );
  }
}
