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

/// One cook as a card: the day set large on the left, then how it went, for
/// how many, and the note. Tappable when [onTap] is given — the detail screen
/// edits through it, history only reads.
class CookEntryLine extends StatelessWidget {
  final CookEntry entry;

  /// The stars' colour; the theme's accent when not given.
  final Color? accent;
  final VoidCallback? onTap;

  const CookEntryLine({super.key, required this.entry, this.accent, this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: scheme.onSurfaceVariant,
    );
    final local = entry.date.toLocal();
    final servings = entry.servings;
    return Material(
      color: scheme.surface,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // The whole date for a screen reader; the two big parts for the
              // eye.
              Semantics(
                label: formatDay(entry.date),
                excludeSemantics: true,
                child: SizedBox(
                  width: 44,
                  child: Column(
                    children: [
                      Text(
                        '${local.day}',
                        style: const TextStyle(
                          fontFamily: 'InstrumentSerif',
                          fontSize: 32,
                          height: 1,
                        ),
                      ),
                      Text(
                        formatDay(entry.date).split(' ')[1].toUpperCase(),
                        style: muted?.copyWith(letterSpacing: 0.6),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        if (entry.stars > 0)
                          StarsRow(
                            stars: entry.stars,
                            accent: accent ?? scheme.primary,
                            size: 16,
                          )
                        else
                          Text('No stars', style: muted),
                        const Spacer(),
                        if (servings != null)
                          Text('Served $servings', style: muted),
                      ],
                    ),
                    if (entry.note.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(
                          entry.note,
                          style: TextStyle(
                            fontFamily: 'InstrumentSerif',
                            fontStyle: FontStyle.italic,
                            fontSize: 18,
                            height: 1.3,
                            color: scheme.onSurface.withValues(alpha: 0.86),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
