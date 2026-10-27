import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';

import '../recipe_models.dart';
import '../recipe_parser.dart';
import '../recipe_server.dart';
import '../recipe_store.dart';
import 'glass.dart';
import 'pro_screen.dart' show writeOrUpgrade;

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

  /// A dish, an idea or a link, for the server to write up.
  final _ask = TextEditingController();
  List<String> _askErrors = const [];

  @override
  void dispose() {
    _controller.dispose();
    _ask.dispose();
    super.dispose();
  }

  /// One box for a sentence and a link: a link is the whole box and nothing
  /// else, which no description of a dish ever is.
  Future<void> _write() async {
    final text = _ask.text.trim();
    if (text.isEmpty) return;
    final link = Uri.tryParse(text);
    final isLink =
        !text.contains(' ') &&
        link != null &&
        (link.isScheme('https') || link.isScheme('http')) &&
        link.host.isNotEmpty;
    await _fromServer(
      isLink ? 'Reading the page…' : 'Writing the recipe…',
      () => isLink ? askForRecipe(url: text) : askForRecipe(text: text),
    );
  }

  Future<void> _fromPhoto() async {
    final XFile? picked;
    try {
      // Shrunk the way the editor's picker shrinks: a cookbook page reads fine
      // at 1600px, and it is uploaded whole.
      picked = await ImagePicker().pickImage(
        source: ImageSource.gallery,
        maxWidth: 1600,
        imageQuality: 85,
      );
    } on MissingPluginException {
      _say('Choosing a photo needs a phone or tablet.');
      return;
    }
    if (picked == null) return;
    final bytes = await picked.readAsBytes();
    await _fromServer(
      'Reading the photo…',
      () => askForRecipe(image: (photoType(picked!.name), bytes)),
    );
  }

  /// Runs [ask] behind [whileWriting], then treats what comes back like any
  /// paste: parsed by the phone's own validator before it is saved.
  Future<void> _fromServer(
    String message,
    Future<String> Function() ask,
  ) async {
    setState(() => _askErrors = const []);
    final Recipe recipe;
    try {
      recipe = widget.parser.parse(
        await writeOrUpgrade(context, message, ask),
      );
    } on RecipeValidationException catch (e) {
      if (mounted) setState(() => _askErrors = e.errors);
      return;
    } on ServerRecipeException catch (e) {
      _say(e.message);
      return;
    }
    final id = await widget.store.save(recipe);
    if (mounted) Navigator.pop(context, (id, recipe));
  }

  void _say(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
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
        if (serverRecipesOn) ...[
          Text('Have mise write it', style: theme.textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(
            'Describe a dish, paste a recipe link, or pick a photo of a '
            'cookbook page.',
            style: muted,
          ),
          if (_askErrors.isNotEmpty)
            ErrorList(
              errors: _askErrors,
              tip: 'Try again, or say it a different way.',
            ),
          const SizedBox(height: 10),
          TextField(
            controller: _ask,
            textInputAction: TextInputAction.go,
            onSubmitted: (_) => _write(),
            decoration: const InputDecoration(
              hintText: 'Lemon drizzle cake for eight',
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              FilledButton.tonal(
                onPressed: _write,
                child: const Text('Write it'),
              ),
              const SizedBox(width: 10),
              OutlinedButton.icon(
                onPressed: _fromPhoto,
                icon: const Icon(Icons.photo_outlined, size: 18),
                label: const Text('From a photo'),
              ),
            ],
          ),
          const SizedBox(height: 28),
          Text('Or bring your own', style: theme.textTheme.titleMedium),
          const SizedBox(height: 16),
        ],
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

/// Holds the screen behind a progress dialog while [work] runs. Blocking on
/// purpose: a server recipe takes seconds, and nothing on the screen behind it
/// means anything until it lands. The bar animates forever, so it is only ever
/// up while a real request is out — never in a test, where the server is off.
Future<T> whileWriting<T>(
  BuildContext context,
  String message,
  Future<T> Function() work,
) async {
  final navigator = Navigator.of(context, rootNavigator: true);
  unawaited(
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) => PopScope(
        canPop: false,
        child: AlertDialog(
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(message),
              const SizedBox(height: 16),
              const LinearProgressIndicator(),
            ],
          ),
        ),
      ),
    ),
  );
  try {
    return await work();
  } finally {
    navigator.pop();
  }
}

/// The shared prompt, plus what only a copy-and-paste needs: where the JSON
/// goes and how it gets back into the app.
String _prompt(RecipeParser parser) =>
    '${parser.prompt}\n'
    'Put the whole JSON in one ```json code block, and put nothing else in '
    'that block — no comments, no notes, no text before or after the object. '
    'Anything you want to tell me about the recipe goes outside the block. '
    'I will copy that block and paste it into mise: open the app, tap '
    'Import recipe, tap Paste, then tap Import.';
