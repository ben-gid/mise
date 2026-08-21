import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../recipe_models.dart';
import '../recipe_parser.dart';
import '../recipe_scaling.dart';
import '../recipe_store.dart';
import 'glass.dart';
import 'recipe_edit_screen.dart';
import 'recipe_history_screen.dart';

/// Shows one recipe, with amounts and step text scaled live by servings.
class RecipeDetailScreen extends StatefulWidget {
  final String id;
  final Recipe recipe;
  final RecipeStore store;

  /// Edits are rebuilt into JSON and put back through here, so an inline tweak
  /// is validated exactly like an import.
  final RecipeParser parser;

  const RecipeDetailScreen({
    super.key,
    required this.id,
    required this.recipe,
    required this.store,
    required this.parser,
  });

  @override
  State<RecipeDetailScreen> createState() => _RecipeDetailScreenState();
}

class _RecipeDetailScreenState extends State<RecipeDetailScreen> {
  /// The version on screen. Editing swaps these for the newly saved version
  /// in place, rather than pushing another copy of this screen.
  late String _id = widget.id;
  late Recipe _recipe = widget.recipe;

  late int _servings = widget.recipe.baseServings;
  final _noteController = TextEditingController();
  int _stars = 0;

  @override
  void initState() {
    super.initState();
    // Unrated is the default state, so there is nothing to show while this
    // resolves — no spinner, which would hang pumpAndSettle.
    widget.store.rating(_id).then((rating) {
      if (rating == null || !mounted) return;
      setState(() => _stars = rating.stars);
      _noteController.text = rating.note;
    });
  }

  /// Shows [saved] as the current version. The rating is cleared rather than
  /// carried over: versions are rated independently, so leaving the old stars
  /// on screen would imply this version had already been cooked.
  void _adopt(SavedRecipe saved) {
    setState(() {
      _id = saved.$1;
      _recipe = saved.$2;
      _stars = 0;
    });
    _noteController.clear();
  }

  Future<void> _edit() async {
    final saved = await Navigator.push<SavedRecipe>(
      context,
      MaterialPageRoute(
        builder: (_) => RecipeEditScreen(
          id: _id,
          recipe: _recipe,
          store: widget.store,
          parser: widget.parser,
        ),
      ),
    );
    if (saved != null && mounted) _adopt(saved);
  }

  Future<void> _openHistory() async {
    final restored = await Navigator.push<SavedRecipe>(
      context,
      MaterialPageRoute(
        builder: (_) => RecipeHistoryScreen(id: _id, store: widget.store),
      ),
    );
    if (restored != null && mounted) _adopt(restored);
  }

  @override
  void dispose() {
    _noteController.dispose();
    super.dispose();
  }

  // ponytail: rewrites the whole ratings map per keystroke; debounce if that
  // file ever gets big.
  void _save() {
    widget.store.setRating(_id, (stars: _stars, note: _noteController.text));
  }

  /// Native share sheet, carrying the recipe scaled to the servings on screen.
  Future<void> _share() async {
    // iPad anchors the share popover to a rect; without one it throws. The
    // screen's own box centres it, which is fine for a single app-bar button.
    final box = context.findRenderObject() as RenderBox?;
    await SharePlus.instance.share(
      ShareParams(
        text: formatForSharing(_recipe, _servings),
        subject: _recipe.title,
        sharePositionOrigin: box == null
            ? null
            : box.localToGlobal(Offset.zero) & box.size,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final recipe = _recipe;
    final theme = Theme.of(context);
    final factor = scaleFactor(recipe, _servings);
    // Tag Prism: the recipe arrives carrying its own light.
    final accent = tagAccent(context, recipe.tags);

    return GlassScaffold(
      tint: accent,
      appBar: glassAppBar(
        context,
        title: Text(recipe.title),
        actions: [
          IconButton(
            onPressed: _openHistory,
            tooltip: 'Version history',
            icon: const Icon(Icons.history),
          ),
          IconButton(
            onPressed: _edit,
            tooltip: 'Edit recipe',
            icon: const Icon(Icons.edit_outlined),
          ),
          IconButton(
            onPressed: _share,
            tooltip: 'Share recipe',
            icon: const Icon(Icons.share),
          ),
        ],
      ),
      body: ListView(
        padding: EdgeInsets.fromLTRB(
          16,
          16 + glassAppBarInset(context),
          16,
          32,
        ),
        children: [
          Row(
            children: [
              for (var star = 1; star <= 5; star++)
                IconButton(
                  // Tapping the current rating clears it — no extra button.
                  onPressed: () {
                    setState(() => _stars = _stars == star ? 0 : star);
                    _save();
                  },
                  icon: Icon(
                    star <= _stars ? Icons.star : Icons.star_border,
                    color: star <= _stars ? accent : null,
                  ),
                ),
            ],
          ),
          TextField(
            controller: _noteController,
            minLines: 1,
            maxLines: 3,
            decoration: const InputDecoration(
              labelText: 'My note',
              border: OutlineInputBorder(),
            ),
            onChanged: (_) => _save(),
          ),
          const SizedBox(height: 24),
          if (recipe.description.isNotEmpty) ...[
            Text(recipe.description, style: theme.textTheme.bodyLarge),
            const SizedBox(height: 16),
          ],
          _ServingsStepper(
            servings: _servings,
            onChanged: (value) => setState(() => _servings = value),
          ),
          const SizedBox(height: 24),
          Text('Ingredients', style: theme.textTheme.titleLarge),
          const SizedBox(height: 8),
          for (final ingredient in recipe.ingredients)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 5),
              // The amount sits in the run of text, so a long name wraps under
              // it instead of into a narrow second column. It stays a
              // WidgetSpan only so it can crossfade when the servings change;
              // the baseline alignment is what keeps it reading as one line.
              child: Text.rich(
                TextSpan(
                  children: [
                    WidgetSpan(
                      alignment: PlaceholderAlignment.baseline,
                      baseline: TextBaseline.alphabetic,
                      child: Padding(
                        padding: const EdgeInsets.only(right: 6),
                        child: _Amount(
                          label: amountLabel(ingredient, factor),
                          accent: accent,
                        ),
                      ),
                    ),
                    TextSpan(text: ingredient.name),
                  ],
                ),
                style: theme.textTheme.bodyLarge,
              ),
            ),
          const SizedBox(height: 24),
          Text('Steps', style: theme.textTheme.titleLarge),
          const SizedBox(height: 8),
          for (final (index, step) in recipe.steps.indexed)
            _StepCard(
              number: index + 1,
              step: step,
              recipe: recipe,
              factor: factor,
              accent: accent,
            ),
          if (recipe.notes case final notes? when notes.isNotEmpty) ...[
            const SizedBox(height: 24),
            Text('Notes', style: theme.textTheme.titleLarge),
            const SizedBox(height: 8),
            Text(notes, style: theme.textTheme.bodyLarge),
          ],
          if (recipe.tags.isNotEmpty) ...[
            const SizedBox(height: 24),
            Wrap(
              spacing: 8,
              children: [for (final tag in recipe.tags) Chip(label: Text(tag))],
            ),
          ],
          const SizedBox(height: 16),
          Text('Source: ${recipe.source}', style: theme.textTheme.bodySmall),
        ],
      ),
    );
  }
}

class _ServingsStepper extends StatelessWidget {
  final int servings;
  final ValueChanged<int> onChanged;

  const _ServingsStepper({required this.servings, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return GlassPanel(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
        child: Row(
          children: [
            Text('Servings', style: theme.textTheme.titleMedium),
            const Spacer(),
            IconButton.outlined(
              onPressed: servings > 1 ? () => onChanged(servings - 1) : null,
              icon: const Icon(Icons.remove),
            ),
            SizedBox(
              width: 48,
              child: Text(
                '$servings',
                textAlign: TextAlign.center,
                style: theme.textTheme.titleLarge,
              ),
            ),
            IconButton.outlined(
              onPressed: () => onChanged(servings + 1),
              icon: const Icon(Icons.add),
            ),
          ],
        ),
      ),
    );
  }
}

/// The signature: live scaling is what this app is for, so the amount wears the
/// recipe's own accent — the same light the stars and step numbers carry — to
/// mark it as the token the servings stepper moves.
class _Amount extends StatelessWidget {
  final String label;
  final Color accent;

  const _Amount({required this.label, required this.accent});

  @override
  Widget build(BuildContext context) {
    final reduced = MediaQuery.disableAnimationsOf(context);
    return AnimatedSwitcher(
      // Finite, and only ever triggered by the servings stepper. Anything that
      // loops here would hang pumpAndSettle.
      duration: reduced ? Duration.zero : const Duration(milliseconds: 180),
      child: Text(
        label,
        key: ValueKey(label),
        style: Theme.of(context).textTheme.bodyLarge?.copyWith(
          color: accent,
          // Weight carries the same signal as the colour, for anyone who
          // can't separate the accent hue from the body ink.
          fontWeight: FontWeight.w600,
          // Numerals go monospaced, so an amount reads as a measured value
          // rather than a word — the distinction the fill used to make.
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
    );
  }
}

class _StepCard extends StatelessWidget {
  final int number;
  final RecipeStep step;
  final Recipe recipe;
  final double factor;
  final Color accent;

  const _StepCard({
    required this.number,
    required this.step,
    required this.recipe,
    required this.factor,
    required this.accent,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return GlassPanel(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                CircleAvatar(
                  radius: 14,
                  backgroundColor: accent,
                  child: Text(
                    '$number',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: onAccent(accent),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(step.title, style: theme.textTheme.titleMedium),
                ),
                if (step.timerSeconds case final seconds?)
                  Chip(
                    avatar: const Icon(Icons.timer_outlined, size: 16),
                    label: Text(formatDuration(seconds)),
                    visualDensity: VisualDensity.compact,
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              renderContent(step, recipe, factor),
              style: theme.textTheme.bodyLarge,
            ),
          ],
        ),
      ),
    );
  }
}
