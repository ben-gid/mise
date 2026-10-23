import 'dart:convert';

import 'package:flutter/material.dart';

import '../recipe_diff.dart';
import '../recipe_models.dart';
import '../recipe_parser.dart';
import '../recipe_store.dart';
import 'cook_log.dart';
import 'glass.dart';

/// Every version of one recipe, newest first: what changed at each edit, and
/// every time that version was cooked.
///
/// Cook logs are per-version on purpose, so this is where "v2 was the good
/// one" becomes visible — the diff says what you did, the stars say whether it
/// worked.
///
/// Pops with the restored [SavedRecipe] if the user restores one.
class RecipeHistoryScreen extends StatefulWidget {
  final String id;
  final RecipeStore store;

  /// For an undo, which can make a recipe no version ever was.
  final RecipeParser parser;

  const RecipeHistoryScreen({
    super.key,
    required this.id,
    required this.store,
    required this.parser,
  });

  @override
  State<RecipeHistoryScreen> createState() => _RecipeHistoryScreenState();
}

/// One version, its cook log, and what it changed from the version before it.
typedef _Version = ({
  SavedRecipe saved,
  List<CookEntry> entries,
  List<RecipeChange> changes,
  bool forked,
});

class _RecipeHistoryScreenState extends State<RecipeHistoryScreen> {
  late final Future<List<_Version>> _versions = _load();

  Future<List<_Version>> _load() async {
    final chain = await widget.store.history(widget.id);
    final forked = await widget.store.forked();
    // ponytail: re-reads ratings.meta once per version; batch if chains
    // ever get long.
    final logs = await Future.wait(
      chain.map((saved) => widget.store.entries(saved.$1)),
    );
    return [
      for (final (index, saved) in chain.indexed)
        (
          saved: saved,
          entries: logs[index],
          // The chain runs newest first, so a version's parent is the next
          // entry along. The oldest has none — it is the original.
          changes: index + 1 < chain.length
              ? diffRecipes(chain[index + 1].$2, saved.$2)
              : const <RecipeChange>[],
          forked: forked.contains(saved.$1),
        ),
    ];
  }

  Future<void> _restore(_Version version) async {
    // Append rather than rewrite: restoring is a new version on top, so the
    // versions it undoes stay on the record. Nothing is ever deleted here.
    final restored = await widget.store.saveVersion(
      version.saved.$2,
      parent: widget.id,
    );
    if (mounted) Navigator.pop(context, restored);
  }

  /// Takes one version's own changes back out of the current recipe, as a new
  /// version on top — unlike [_restore], every edit made since it stays.
  ///
  /// Validated, unlike a restore: a restored version was valid once, but an
  /// undo can make a combination nothing ever was, like a step naming an
  /// ingredient the undo removes.
  Future<void> _undo(List<_Version> versions, int index) async {
    final current = versions.first.saved.$2;
    final undone = undoChanges(
      parent: versions[index + 1].saved.$2,
      version: versions[index].saved.$2,
      current: current,
    );
    final messenger = ScaffoldMessenger.of(context);
    if (jsonEncode(undone) == jsonEncode(current.toJson())) {
      messenger.showSnackBar(
        const SnackBar(
          content: Text(
            'Nothing left to undo — each of these was edited again '
            'since.',
          ),
        ),
      );
      return;
    }
    final Recipe recipe;
    try {
      recipe = widget.parser.parse(jsonEncode(undone));
    } on RecipeValidationException catch (e) {
      messenger.showSnackBar(
        SnackBar(
          content: Text("Can't undo this on its own: ${e.errors.first}"),
        ),
      );
      return;
    }
    final saved = await widget.store.saveVersion(recipe, parent: widget.id);
    if (mounted) Navigator.pop(context, saved);
  }

  @override
  Widget build(BuildContext context) {
    final appBarInset = glassAppBarInset(context);
    return GlassScaffold(
      appBar: glassAppBar(context, title: const Text('History')),
      body: FutureBuilder<List<_Version>>(
        future: _versions,
        builder: (context, snapshot) {
          // Blank rather than a spinner while the read lands: an indefinite
          // animation never lets pumpAndSettle return.
          if (!snapshot.hasData) return const SizedBox.shrink();
          final versions = snapshot.data!;
          return ListView.builder(
            padding: EdgeInsets.only(top: appBarInset + 8, bottom: 32),
            itemCount: versions.length,
            itemBuilder: (context, index) => _VersionCard(
              version: versions[index],
              // Counted from the original so the numbering doesn't shift as
              // more versions are added on top.
              number: versions.length - index,
              isCurrent: index == 0,
              isOriginal: index == versions.length - 1,
              onRestore: () => _restore(versions[index]),
              onUndo: () => _undo(versions, index),
            ),
          );
        },
      ),
    );
  }
}

class _VersionCard extends StatelessWidget {
  final _Version version;
  final int number;
  final bool isCurrent;
  final bool isOriginal;
  final VoidCallback onRestore;
  final VoidCallback onUndo;

  const _VersionCard({
    required this.version,
    required this.number,
    required this.isCurrent,
    required this.isOriginal,
    required this.onRestore,
    required this.onUndo,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = theme.colorScheme.primary;
    final entries = version.entries;

    return GlassPanel(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    isOriginal ? 'Original' : 'Version $number',
                    style: theme.textTheme.titleMedium,
                  ),
                ),
                if (isCurrent)
                  Chip(
                    label: const Text('Current'),
                    visualDensity: VisualDensity.compact,
                    backgroundColor: accent.withValues(alpha: 0.22),
                  ),
              ],
            ),
            const SizedBox(height: 2),
            Text(
              // A fork's diff is against the other phone's edit, not the
              // version this one was made from — so say so.
              version.forked
                  ? '${_formatDate(version.saved.$2.createdAt)} · '
                        'Edited on another device'
                  : _formatDate(version.saved.$2.createdAt),
              style: theme.textTheme.bodySmall,
            ),
            if (entries.isNotEmpty) ...[
              const SizedBox(height: 8),
              if (headlineStars(entries) case final stars when stars > 0)
                StarsRow(stars: stars, accent: accent, size: 18),
              // The whole log, not the detail screen's latest two: this is
              // where versions get compared.
              for (final entry in entries)
                CookEntryLine(entry: entry, accent: accent),
            ],
            const SizedBox(height: 12),
            if (isOriginal)
              Text(
                'Imported from ${version.saved.$2.source}',
                style: theme.textTheme.bodyMedium,
              )
            else if (version.changes.isEmpty)
              Text('Saved with no changes', style: theme.textTheme.bodyMedium)
            else
              for (final change in version.changes) _ChangeRow(change: change),
            // Two ways back, because the card shows a *change* and a version
            // is a whole recipe: Undo takes out what's listed above and keeps
            // every later edit; Restore brings back this version entire,
            // undoing everything since. A Wrap, so a narrow phone stacks them.
            if (!isOriginal && version.changes.isNotEmpty || !isCurrent) ...[
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  if (!isOriginal && version.changes.isNotEmpty)
                    OutlinedButton.icon(
                      onPressed: onUndo,
                      icon: const Icon(Icons.undo, size: 18),
                      label: const Text('Undo these changes'),
                    ),
                  if (!isCurrent)
                    OutlinedButton.icon(
                      onPressed: onRestore,
                      icon: const Icon(Icons.restore, size: 18),
                      label: const Text('Restore this version'),
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// One changed field, as a diff.
///
/// Three shapes for three things, because a recipe knows which is which where
/// git does not: git pairs a minus and a plus for a modification only because
/// it cannot tell whether two lines are related. These changes are matched by
/// id, so a swap is drawn as one line that becomes another, and only a real
/// arrival or departure gets the green or the red.
///
/// Colour is never the only signal — every line is marked in its gutter, and
/// the badge says it again in words.
class _ChangeRow extends StatelessWidget {
  final RecipeChange change;

  const _ChangeRow({required this.change});

  @override
  Widget build(BuildContext context) {
    final before = change.before;
    final after = change.after;
    final isAdded = before == null && after != null;
    final isRemoved = before != null && after == null;

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _Badge(change: change, isAdded: isAdded, isRemoved: isRemoved),
          if (isAdded)
            _BandedLine(
              marker: '+',
              color: diffAdded(context),
              child: _value(context, after, diffAdded(context)),
            )
          else if (isRemoved)
            _BandedLine(
              marker: '\u2212',
              color: diffRemoved(context),
              child: _value(context, before, diffRemoved(context)),
            )
          // Both null is a reorder: nothing to quote, so the badge says it all.
          else if (before != null && after != null)
            _BandedLine(
              marker: '~',
              color: diffChanged(context),
              child: _Swap(before: before, after: after),
            ),
        ],
      ),
    );
  }
}

/// One side of a change, in the colour of what happened to it.
Widget _value(BuildContext context, String text, Color color) =>
    Text(text, style: _lineStyle(context, color, bold: false));

TextStyle? _lineStyle(
  BuildContext context,
  Color color, {
  required bool bold,
}) => Theme.of(context).textTheme.bodyMedium?.copyWith(
  color: color,
  height: 1.4,
  fontWeight: bold ? FontWeight.w600 : null,
  // The two halves are read against each other, so digits line up column for
  // column: 60 against 120 rather than two sentences.
  fontFeatures: const [FontFeature.tabularFigures()],
);

/// What a value was, and what it became. Reads across on one line when both
/// halves are short, and stacks when they are not — a paragraph of step
/// wording with an arrow buried mid-sentence hides the very thing it is
/// pointing at.
class _Swap extends StatelessWidget {
  final String before;
  final String after;

  const _Swap({required this.before, required this.after});

  /// Roughly what fits on one phone-width line once the gutter is taken out.
  // ponytail: a character count, not a real measurement. Swap in a
  // LayoutBuilder if a value ever straddles this awkwardly.
  static const _inlineLimit = 44;

  @override
  Widget build(BuildContext context) {
    final changed = diffChanged(context);
    // The old value stays in body ink: colouring both halves would make the
    // row a puzzle about which one is current. Only what the recipe says now
    // carries the accent.
    final was = _lineStyle(
      context,
      Theme.of(context).colorScheme.onSurfaceVariant,
      bold: false,
    );
    final now = _lineStyle(context, changed, bold: true);

    if (before.length + after.length <= _inlineLimit) {
      return Text.rich(
        TextSpan(
          children: [
            TextSpan(text: before, style: was),
            TextSpan(
              text: '  \u2192  ',
              style: now?.copyWith(fontWeight: FontWeight.w700),
            ),
            TextSpan(text: after, style: now),
          ],
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(before, style: was),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Icon(Icons.arrow_downward, size: 14, color: changed),
        ),
        Text(after, style: now),
      ],
    );
  }
}

/// "+1 ingredient", "1 tag", or a swap and the part that moved.
class _Badge extends StatelessWidget {
  final RecipeChange change;
  final bool isAdded;
  final bool isRemoved;

  const _Badge({
    required this.change,
    required this.isAdded,
    required this.isRemoved,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final counted = change.kind.countable && (isAdded || isRemoved);
    final color = counted
        ? (isAdded ? diffAdded(context) : diffRemoved(context))
        : theme.colorScheme.onSurfaceVariant;
    // The sign is carried by the icon, so the words stay words.
    final icon = counted
        ? (isAdded ? Icons.add : Icons.remove)
        : Icons.swap_horiz;
    final text = counted
        ? '1 ${change.kind.noun}'
        : [change.label.toLowerCase(), ?change.detail].join(' \u00b7 ');

    return Padding(
      padding: const EdgeInsets.only(bottom: 4, left: 2),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              text,
              style: theme.textTheme.labelSmall?.copyWith(
                color: color,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.3,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A tinted band with a one-character gutter, the way a diff marks its lines.
class _BandedLine extends StatelessWidget {
  final String marker;
  final Color color;
  final Widget child;

  const _BandedLine({
    required this.marker,
    required this.color,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 2),
      padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 8),
      decoration: BoxDecoration(
        color: diffBand(context, color),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 16,
            child: Text(
              marker,
              textAlign: TextAlign.center,
              style: _lineStyle(
                context,
                color,
                bold: true,
              )?.copyWith(fontWeight: FontWeight.w700),
            ),
          ),
          Expanded(child: child),
        ],
      ),
    );
  }
}

/// "17 Aug 2026, 14:32" — local time, since it is the user's own edit.
String _formatDate(DateTime date) {
  final local = date.toLocal();
  final minute = local.minute.toString().padLeft(2, '0');
  return '${formatDay(local)}, ${local.hour}:$minute';
}
