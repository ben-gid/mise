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
    return GlassScaffold(
      appBar: glassAppBar(
        context,
        title: const Text('Import recipe'),
        actions: [
          TextButton.icon(
            onPressed: _copyPrompt,
            icon: const Icon(Icons.content_copy, size: 18),
            label: const Text('Copy prompt'),
          ),
        ],
      ),
      body: Padding(
        padding: EdgeInsets.fromLTRB(
          16,
          16 + glassAppBarInset(context),
          16,
          16,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Paste the JSON an LLM gave you. It is validated against the '
              'recipe schema before anything is saved.',
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 12),
            Expanded(
              child: TextField(
                controller: _controller,
                maxLines: null,
                expands: true,
                textAlignVertical: TextAlignVertical.top,
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
                  height: 1.4,
                ),
                decoration: const InputDecoration(
                  hintText: '{\n  "title": "…",\n  "base_servings": 4,\n  …\n}',
                  alignLabelWithHint: true,
                ),
                onChanged: (_) {
                  if (_errors.isNotEmpty) setState(() => _errors = const []);
                },
              ),
            ),
            if (_errors.isNotEmpty) ErrorList(errors: _errors),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _pasteFromClipboard,
                    icon: const Icon(Icons.paste),
                    label: const Text('Paste'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _import,
                    icon: const Icon(Icons.check),
                    label: const Text('Import'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Every problem at once, not just the first — the reason the parser collects
/// them. Shared with the editor so a rejected save reads the same either way.
class ErrorList extends StatelessWidget {
  final List<String> errors;

  const ErrorList({super.key, required this.errors});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      constraints: const BoxConstraints(maxHeight: 200),
      margin: const EdgeInsets.only(top: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: colors.errorContainer,
        borderRadius: BorderRadius.circular(panelRadius),
        border: Border.all(color: colors.error.withValues(alpha: 0.4)),
      ),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${errors.length} problem${errors.length == 1 ? '' : 's'} — '
              'nothing was saved',
              style: TextStyle(
                fontWeight: FontWeight.bold,
                color: colors.onErrorContainer,
              ),
            ),
            const SizedBox(height: 6),
            for (final error in errors)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  '• $error',
                  style: TextStyle(
                    color: colors.onErrorContainer,
                    fontSize: 13,
                  ),
                ),
              ),
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
    'resting, chilling, simmering.\n'
    '- Set density_g_per_ml on every ingredient that could reasonably be '
    'measured either way, so the reader can switch between weight and volume. '
    'Omit it only for countable items and pinches.\n'
    '- Put a photo url in image_urls only if you are confident it exists — '
    'one you looked up, not one you reconstructed. Leave it empty otherwise: '
    'a guessed CDN path 404s, and padding the list with more guesses just '
    'fails three ways at once. The app falls back to a photo of the dish, so '
    'no url beats an invented one. If you can search the web, do that for this '
    'field rather than skipping it.\n'
    '- Each must be a direct https link to the image file itself, not to the '
    'page the image sits on.\n'
    '- Prefer sources whose image urls are stable and public — Wikimedia '
    'Commons especially — over guessing a food blog CDN path, which is '
    'usually hashed or dated and will not resolve.\n'
    '- created_at is the current time in ISO 8601.';
