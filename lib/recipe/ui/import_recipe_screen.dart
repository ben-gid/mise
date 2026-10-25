import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../recipe_models.dart';
import '../recipe_parser.dart';
import '../recipe_store.dart';
import 'glass.dart';

/// Paste JSON from an LLM, validate it, save it. Validation errors are shown
/// in full rather than as a single "invalid" — the whole point of the schema.

class ImportRecipeScreen extends StatefulWidget {
  final RecipeStore store;
  final RecipeParser parser;

  const ImportRecipeScreen({
    super.key,
    required this.store,
    required this.parser,
  });

  @override
  State<ImportRecipeScreen> createState() => _ImportRecipeScreenState();
}

class _ImportRecipeScreenState extends State<ImportRecipeScreen> {
  final _controller = TextEditingController();
  List<String> _errors = const [];

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _import() async {
    final Recipe recipe;
    try {
      recipe = widget.parser.parse(_controller.text);
    } on RecipeValidationException catch (e) {
      setState(() => _errors = e.errors);
      return;
    }
    final id = await widget.store.save(recipe);
    if (mounted) Navigator.pop(context, (id, recipe));
  }

  Future<void> _pasteFromClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (data?.text != null) {
      _controller.text = data!.text!;
      setState(() => _errors = const []);
    }
  }

  Future<void> _copyPrompt() async {
    await Clipboard.setData(ClipboardData(text: _prompt(widget.parser)));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Prompt copied — paste it to an LLM')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodyMedium?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    return SpreadPage(
      title: 'Import a recipe',
      subtitle: 'Ask any chat model for a recipe, then paste its answer here.',
      bottom: FilledButton(
        onPressed: _import,
        style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(54)),
        child: const Text('Import'),
      ),
      children: [
        _Step(
          number: 1,
          title: 'Copy the prompt',
          children: [
            Text(
              'It carries the schema, so the model writes a recipe mise can '
              'read.',
              style: muted,
            ),
            const SizedBox(height: 10),
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                onPressed: _copyPrompt,
                icon: const Icon(Icons.content_copy, size: 18),
                label: const Text('Copy prompt'),
              ),
            ),
          ],
        ),
        const SizedBox(height: 24),
        _Step(
          number: 2,
          title: 'Paste what it gave you',
          action: TextButton.icon(
            onPressed: _pasteFromClipboard,
            style: TextButton.styleFrom(backgroundColor: glassFill(context)),
            icon: const Icon(Icons.content_paste, size: 18),
            label: const Text('Paste'),
          ),
          children: [
            Text(
              'It is checked against the recipe schema before anything is '
              'saved.',
              style: muted,
            ),
            // Above the box rather than under it: under a tall paste they
            // would land off screen, and these are what to fix in it.
            if (_errors.isNotEmpty)
              ErrorList(
                errors: _errors,
                tip: 'Paste these back to the model and ask it to fix them.',
              ),
            const SizedBox(height: 10),
            TextField(
              controller: _controller,
              minLines: 10,
              maxLines: 18,
              // 'monospace' resolves only on some platforms, so name real
              // families to fall back to rather than silently landing on the
              // proportional default.
              style: const TextStyle(
                fontFamily: 'monospace',
                fontFamilyFallback: [
                  'Menlo',
                  'Consolas',
                  'DejaVu Sans Mono',
                  'Courier New',
                ],
                fontSize: 13,
                height: 1.45,
              ),
              decoration: const InputDecoration(
                hintText: '{\n  "title": "…",\n  "base_servings": 4,\n  …\n}',
              ),
              onChanged: (_) {
                if (_errors.isNotEmpty) setState(() => _errors = const []);
              },
            ),
          ],
        ),
      ],
    );
  }
}

/// One numbered step of the import: a serif numeral in the margin, the way the
/// recipe view numbers its method.
class _Step extends StatelessWidget {
  final int number;
  final String title;
  final Widget? action;
  final List<Widget> children;

  const _Step({
    required this.number,
    required this.title,
    this.action,
    required this.children,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 30,
          child: Text(
            '$number',
            style: serif(
              36,
              height: 0.95,
            ).copyWith(color: theme.colorScheme.primary),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(title, style: theme.textTheme.titleMedium),
                  ),
                  ?action,
                ],
              ),
              const SizedBox(height: 4),
              ...children,
            ],
          ),
        ),
      ],
    );
  }
}

/// Every problem at once, not just the first — the reason the parser collects
/// them. Shared with the editor so a rejected save reads the same either way.
class ErrorList extends StatelessWidget {
  final List<String> errors;

  /// What to do about them, where there is something better than "fix it".
  final String? tip;

  const ErrorList({super.key, required this.errors, this.tip});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Container(
      constraints: const BoxConstraints(maxHeight: 240),
      margin: const EdgeInsets.only(top: 16),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: colors.errorContainer,
        borderRadius: BorderRadius.circular(panelRadius),
      ),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${errors.length} problem${errors.length == 1 ? '' : 's'} — '
              'nothing was saved',
              style: weighted(
                theme.textTheme.bodyLarge,
                FontWeight.w600,
              )?.copyWith(color: colors.error),
            ),
            const SizedBox(height: 6),
            for (final error in errors)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  '• $error',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: colors.onErrorContainer,
                  ),
                ),
              ),
            if (tip case final tip?) ...[
              const SizedBox(height: 8),
              Text(
                tip,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: colors.onSurfaceVariant,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Built from the live schema so it can't drift from what the validator
/// actually enforces.
String _prompt(RecipeParser parser) =>
    'Write a recipe as JSON for the mise recipe app.\n\n'
    'Put the whole JSON in one ```json code block, and put nothing else in '
    'that block — no comments, no notes, no text before or after the object. '
    'Anything you want to tell me about the recipe goes outside the block.\n\n'
    'I will copy that block and paste it into mise: open the app, tap '
    'Import recipe, tap Paste, then tap Import. The app checks it against '
    'this JSON Schema before saving, so it has to match exactly:\n\n'
    '${parser.schemaJson}\n\n'
    'Rules:\n'
    '- Ingredient ids are 4 digits ("0001", "0002", …).\n'
    '- Fold counting nouns into the ingredient name for whole items '
    '("garlic cloves") and set their unit to null.\n'
    '- Give each ingredient a name distinct from the others. Where the same '
    'thing appears in two components, say which: "caster sugar (sponge)" '
    'and "caster sugar (buttercream)", not "caster sugar" twice.\n'
    '- Step content references ingredients inline as {0001} — never repeat the '
    'amount in the text.\n'
    '- Set timer_seconds whenever a step involves waiting: proofing, baking, '
    'resting, chilling, simmering — and for timed cooking on the stove, like '
    'browning mushrooms for six minutes or reducing wine for two. Not for '
    'hands-on work like whisking, creaming or kneading.\n'
    '- Set density_g_per_ml on every ingredient that could reasonably be '
    'measured either way, so the reader can switch between weight and volume. '
    'Omit it only for countable items and pinches.\n'
    '- Set image_query to two to four words for what the finished dish looks '
    'like, the way you would type it into a stock photo search: "rustic '
    'focaccia bread", "creamy mushroom pasta". Describe the food, not the '
    'recipe — not its title, not a cuisine or a person\'s name, nothing a '
    'camera cannot see. A dish\'s common name is fine where a photographer '
    'would tag the photo with it: "victoria sponge cake", "pad thai". The app '
    'searches a photo library with it.\n'
    '- Leave image_urls out entirely. The app fills it in when the cook picks '
    'a photo, and a url from you would override that pick with a link that is '
    'usually dead.\n'
    '- Write notes last, once the rest of the recipe is on the page: it is '
    'the headnote the app prints above the ingredients, so it wants what a '
    'cookbook puts there — where the dish comes from, when to make it, what '
    'can be substituted, the tip that decides whether it works. Prose, not a '
    'recap of the steps.\n'
    '- created_at is the current time in ISO 8601.';
