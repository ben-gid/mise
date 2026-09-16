import 'dart:convert';

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';

import '../recipe_image.dart';
import '../recipe_models.dart';
import '../recipe_parser.dart';
import '../recipe_refs.dart';
import '../recipe_scaling.dart';
import '../recipe_store.dart';
import 'glass.dart';
import 'import_recipe_screen.dart' show ErrorList;

/// The one place a recipe is edited, in either of two modes.
///
/// **Form** is the everyday one: fields laid out in the order the recipe reads,
/// with ingredients referenced in step text by name rather than by the `{0001}`
/// id that actually gets stored. **JSON** is the escape hatch and the way a
/// rewrite from an LLM comes back in.
///
/// Both end at the same Save, and both go through [RecipeParser.parse], so
/// neither can write something the schema would reject.
///
/// Pops with the newly saved [SavedRecipe], or null if nothing was saved.
class RecipeEditScreen extends StatefulWidget {
  /// The version being edited — the parent of whatever this screen saves.
  final String id;
  final Recipe recipe;
  final RecipeStore store;
  final RecipeParser parser;

  /// Opens straight into the photo picker. The detail screen's "Add photo"
  /// routes here rather than saving on its own — a photo is an edit like any
  /// other, and a second save path would be a second set of rules.
  final bool pickImageOnOpen;

  const RecipeEditScreen({
    super.key,
    required this.id,
    required this.recipe,
    required this.store,
    required this.parser,
    this.pickImageOnOpen = false,
  });

  @override
  State<RecipeEditScreen> createState() => _RecipeEditScreenState();
}

/// What the user chose when told an ingredient is never used in a step.
enum _UnusedAction { edit, remove, save }

class _RecipeEditScreenState extends State<RecipeEditScreen> {
  final _title = TextEditingController();
  final _servings = TextEditingController();
  final _tags = TextEditingController();
  final _notes = TextEditingController();
  final _imageUrls = TextEditingController();
  final _json = TextEditingController();

  final _ingredients = <_IngredientDraft>[];
  final _steps = <_StepDraft>[];

  bool _jsonMode = false;
  List<String> _errors = const [];

  @override
  void initState() {
    super.initState();
    _load(widget.recipe);
    // After the first frame: _pickImage answers the desktop harness with a
    // SnackBar, and ScaffoldMessenger needs the Scaffold to exist first.
    if (widget.pickImageOnOpen) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _pickImage());
    }
  }

  @override
  void dispose() {
    _title.dispose();
    _servings.dispose();
    _tags.dispose();
    _notes.dispose();
    _imageUrls.dispose();
    _json.dispose();
    _disposeDrafts();
    super.dispose();
  }

  void _disposeDrafts() {
    for (final draft in _ingredients) {
      draft.dispose();
    }
    for (final draft in _steps) {
      draft.dispose();
    }
  }

  /// Fills every field from [recipe]. Used on open and again when JSON mode
  /// hands control back to the form.
  void _load(Recipe recipe) {
    _title.text = recipe.title;
    _servings.text = '${recipe.baseServings}';
    _tags.text = recipe.tags.join(', ');
    _notes.text = recipe.notes ?? '';
    // One per line rather than comma-separated like tags: commas are legal
    // inside a url, and splitting on them would quietly cut one in half.
    _imageUrls.text = recipe.imageUrls.join('\n');

    _disposeDrafts();
    // Seeded with the label rather than the name: the step text below is
    // rendered by [toDisplayRefs], which labels duplicates, so a draft that
    // remembered the bare name would think every reference to it had gone.
    final labels = labelsFor(recipe.ingredients);
    _ingredients
      ..clear()
      ..addAll([
        for (final (n, ingredient) in recipe.ingredients.indexed)
          _IngredientDraft.from(ingredient, labels[n]),
      ]);
    _steps
      ..clear()
      ..addAll(
        recipe.steps.map((step) => _StepDraft.from(step, recipe.ingredients)),
      );
  }

  /// Copies a photo off the device into the store and points the recipe at it.
  ///
  /// Gallery only, deliberately: on iOS 14+ that is PHPicker, which needs no
  /// Info.plist entry, and Android 13+ needs no permission. A camera source
  /// would cost both.
  ///
  /// This writes the file before the edit is saved, so abandoning the edit
  /// leaves it behind — see [RecipeStore.addImage]. It is still not a second
  /// save path: all it does is fill in a text field, and the recipe goes
  /// through [_save] and the parser like every other edit.
  Future<void> _pickImage() async {
    String message;
    try {
      final picked = await ImagePicker().pickImage(source: ImageSource.gallery);
      if (picked == null || !mounted) return;
      final url = await widget.store.addImage(picked.path);
      if (!mounted) return;
      // Replaces the guesses rather than joining them: a local file cannot
      // 404, so nothing behind it could ever be reached.
      setState(() => _imageUrls.text = url);
      return;
    } on MissingPluginException {
      // No Linux implementation, so the desktop harness lands here. The same
      // class of degradation as share_plus falling back to mailto — not a bug,
      // just not a phone.
      message = 'Choosing a photo needs a phone or tablet.';
    } catch (_) {
      message = 'That photo could not be read. Try another.';
    }
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  // ---------------------------------------------------------------- drafting

  List<Ingredient> _draftIngredients() => [
    for (final draft in _ingredients)
      Ingredient(
        id: draft.id,
        name: draft.name.text.trim(),
        // An unparseable amount becomes 0, which the schema rejects with a
        // message naming the ingredient — no second set of rules here.
        amount: num.tryParse(draft.amount.text.trim()) ?? 0,
        unit: draft.unit,
        // Blank means absent, which is valid — unlike amount there is no
        // sentinel that the schema will reject on the user's behalf.
        densityGPerMl: num.tryParse(draft.density.text.trim()),
      ),
  ];

  /// The recipe as the form currently describes it. Always constructible, not
  /// necessarily valid — [_save] is what decides that.
  Recipe _draft() {
    final ingredients = _draftIngredients();
    return Recipe(
      title: _title.text.trim(),
      baseServings:
          int.tryParse(_servings.text.trim()) ?? widget.recipe.baseServings,
      ingredients: ingredients,
      steps: [
        for (final draft in _steps)
          RecipeStep(
            id: draft.id,
            title: draft.title.text.trim(),
            content: toIdRefs(draft.content.text.trim(), ingredients),
            timerSeconds: draft.seconds,
          ),
      ],
      notes: _notes.text.trim().isEmpty ? null : _notes.text.trim(),
      imageUrls: [
        for (final url in _imageUrls.text.split('\n'))
          if (url.trim().isNotEmpty) url.trim(),
      ],
      tags: [
        for (final tag in _tags.text.split(','))
          if (tag.trim().isNotEmpty) tag.trim(),
      ],
      // None of these belong to the user: source records where the recipe came
      // from, createdAt is restamped by saveVersion, and imageQuery is the
      // model's description of the dish, edited from the photo picker rather
      // than from this form. Carried rather than rebuilt — a field on Recipe
      // that is missing here is erased by the first save, silently.
      imageQuery: widget.recipe.imageQuery,
      source: widget.recipe.source,
      createdAt: widget.recipe.createdAt,
    );
  }

  /// The label each ingredient is currently referred to by in step text.
  List<String> _labels() => labelsFor(_draftIngredients());

  /// Moves `[old label]` to `[new label]` in every step after a rename.
  ///
  /// Step text refers to an ingredient by name, not by the id underneath, so a
  /// rename would otherwise strand every reference to it.
  ///
  /// Runs on every keystroke, so the steps track the name as it is typed. Each
  /// call renames from whatever the steps currently say, so "b", "br", "bre"
  /// chains correctly rather than fighting itself.
  ///
  /// Labels, not names, because one keystroke can move two of them: typing
  /// "warm water" down to "water" where a "water" already exists makes both
  /// ingredients duplicates, so both pick up a `#id` and both their references
  /// have to follow. Rewriting in one pass is safe — a new label either has a
  /// different base name from every old one or carries an id suffix no bare
  /// old label can match, so nothing this loop writes can be found by a later
  /// iteration.
  void _applyRenames() {
    final wanted = _labels();
    for (final (index, draft) in _ingredients.indexed) {
      final label = wanted[index];
      if (label.isEmpty || label == draft.knownAs) continue;
      // Nothing can be referencing a just-added ingredient, so there is no
      // `[]` to search for — adopt the label and let the next rename move it.
      if (draft.knownAs.isNotEmpty) {
        for (final step in _steps) {
          step.content.text = step.content.text.replaceAll(
            '[${draft.knownAs}]',
            '[$label]',
          );
        }
      }
      draft.knownAs = label;
    }
  }

  // ------------------------------------------------------------------- modes

  void _setMode(bool json) {
    if (json == _jsonMode) return;
    if (json) {
      _applyRenames();
      setState(() {
        _json.text = const JsonEncoder.withIndent(
          '  ',
        ).convert(_draft().toJson());
        _errors = const [];
        _jsonMode = true;
      });
      return;
    }
    // Coming back the other way the text has to be a real recipe first, or
    // there is nothing to put in the fields.
    final Recipe parsed;
    try {
      parsed = widget.parser.parse(_json.text);
    } on RecipeValidationException catch (e) {
      setState(() => _errors = e.errors);
      return;
    }
    setState(() {
      _load(parsed);
      _errors = const [];
      _jsonMode = false;
    });
  }

  Future<void> _copyRewritePrompt() async {
    await Clipboard.setData(
      ClipboardData(
        text:
            'Rewrite this recipe as JSON for the mise recipe app.\n\n'
            'Put the whole JSON in one ```json code block, and put nothing '
            'else in that block — no comments, no notes. Anything you want to '
            'tell me goes outside the block. I will copy that block and paste '
            'it back into the recipe editor, which checks it against this '
            'JSON Schema before saving:\n\n'
            '${widget.parser.schemaJson}\n\n'
            'Rules:\n'
            '- Keep an ingredient id unchanged when the ingredient itself is '
            'unchanged.\n'
            '- Give each ingredient a name distinct from the others. Where '
            'the same thing appears in two components, say which: "caster '
            'sugar (sponge)" and "caster sugar (buttercream)", not "caster '
            'sugar" twice.\n'
            '- Step content references ingredients inline as {0001} — never '
            'repeat the amount in the text.\n'
            '- Set timer_seconds whenever a step involves waiting.\n'
            '- Set density_g_per_ml on every ingredient that could reasonably '
            'be measured either way, keeping any already there. Omit it only '
            'for countable items and pinches.\n'
            '- Leave image_urls exactly as it is. It holds the photo the '
            'cook chose and is not yours to change.\n'
            '- Set image_query if it is missing, and fix it if it names the '
            'recipe instead of describing it: two to four words for what the '
            'finished dish looks like, as typed into a stock photo search.\n\n'
            'The recipe to rewrite:\n${_json.text}',
      ),
    );
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Prompt copied — paste it to an LLM')),
      );
    }
  }

  // -------------------------------------------------------------- list edits

  void _addIngredient() {
    setState(() {
      _ingredients.add(
        _IngredientDraft.blank(nextIngredientId(_ingredients.map((d) => d.id))),
      );
    });
  }

  /// Removes an ingredient, and takes its references out of the steps that use
  /// it — leaving the words behind rather than a hole in the sentence.
  Future<void> _removeIngredient(int index) async {
    final name = _ingredients[index].name.text.trim();
    final label = _labels()[index];
    final usedIn = [
      for (final (number, draft) in _steps.indexed)
        if (draft.content.text.contains('[$label]')) number + 1,
    ];

    if (usedIn.isNotEmpty) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('Remove $name?'),
          content: Text(
            'It is used in ${_stepList(usedIn)}. The wording there stays as '
            'it is, but $name will no longer scale with the servings.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Keep it'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Remove'),
            ),
          ],
        ),
      );
      if (confirmed != true) return;
    }

    setState(() {
      for (final draft in _steps) {
        // Unbracketed, not deleted: dropping the words would leave "Melt
        // with finely sliced garlic cloves".
        draft.content.text = draft.content.text.replaceAll('[$label]', name);
      }
      _ingredients.removeAt(index).dispose();
    });
  }

  void _addStep() {
    setState(() {
      _steps.add(_StepDraft.blank(nextStepId(_steps.map((d) => d.id))));
    });
  }

  void _removeStep(int index) {
    setState(() => _steps.removeAt(index).dispose());
  }

  // -------------------------------------------------------------------- save

  Future<void> _save() async {
    _applyRenames();
    final ingredients = _draftIngredients();

    // The one check the schema cannot express. Two ingredients may share a
    // name — recipes split by component do it on purpose — so what has to hold
    // is that every bracket names exactly one of them, which is what a label
    // is for.
    final shared = {
      for (final i in ingredients)
        if (ingredients.where((o) => o.name.trim() == i.name.trim()).length > 1)
          i.name.trim(),
    };
    final problems = <String>[
      for (final (number, draft) in _steps.indexed)
        for (final unknown in unresolvedRefs(draft.content.text, ingredients))
          // A bare name that two ingredients answer to reads as unresolved,
          // and saying so would be true but useless — the fix is to pick one,
          // not to invent an ingredient.
          if (shared.contains(unknown))
            'Step ${number + 1} mentions [$unknown], but more than one '
                'ingredient is called that. Tap the one you mean under the '
                'step to replace it.'
          else
            'Step ${number + 1} mentions [$unknown], which is not an '
                'ingredient.',
    ];
    if (problems.isNotEmpty) {
      setState(() => _errors = problems);
      return;
    }

    var recipe = _jsonMode ? null : _draft();
    try {
      recipe = widget.parser.parse(
        recipe == null ? _json.text : jsonEncode(recipe.toJson()),
      );
    } on RecipeValidationException catch (e) {
      setState(() => _errors = e.errors);
      return;
    }

    final unused = unusedIngredients(recipe);
    if (unused.isNotEmpty) {
      final action = await _askAboutUnused(unused);
      if (action == null || action == _UnusedAction.edit) return;
      if (action == _UnusedAction.remove) {
        final json = recipe.toJson();
        final drop = {for (final i in unused) i.id};
        (json['ingredients'] as List).removeWhere(
          (i) => drop.contains((i as Map)['id']),
        );
        try {
          recipe = widget.parser.parse(jsonEncode(json));
        } on RecipeValidationException catch (e) {
          // Removing every ingredient leaves a recipe the schema won't take.
          setState(() => _errors = e.errors);
          return;
        }
      }
    }

    final saved = await widget.store.saveVersion(recipe, parent: widget.id);
    if (mounted) Navigator.pop(context, saved);
  }

  Future<_UnusedAction?> _askAboutUnused(List<Ingredient> unused) {
    final names = unused.map((i) => i.name).join(', ');
    return showDialog<_UnusedAction>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          unused.length == 1
              ? 'One ingredient is never used'
              : '${unused.length} ingredients are never used',
        ),
        content: Text(
          'No step mentions $names. They will still be listed and still scale '
          'with the servings, but nothing tells the cook when to use them.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, _UnusedAction.edit),
            child: const Text('Back to editing'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, _UnusedAction.remove),
            child: Text(unused.length == 1 ? 'Remove it' : 'Remove them'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, _UnusedAction.save),
            child: const Text('Save anyway'),
          ),
        ],
      ),
    );
  }

  // ------------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    final accent = tagAccent(context, widget.recipe.tags);
    return GlassScaffold(
      tint: accent,
      appBar: glassAppBar(context, title: const Text('Edit recipe')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _save,
        icon: const Icon(Icons.check),
        label: const Text('Save version'),
      ),
      body: ListView(
        padding: EdgeInsets.fromLTRB(
          16,
          16 + glassAppBarInset(context),
          16,
          96,
        ),
        children: [
          SegmentedButton<bool>(
            segments: const [
              ButtonSegment(value: false, label: Text('Form')),
              ButtonSegment(value: true, label: Text('JSON')),
            ],
            selected: {_jsonMode},
            onSelectionChanged: (selection) => _setMode(selection.first),
          ),
          const SizedBox(height: 16),
          if (_errors.isNotEmpty) ...[
            ErrorList(errors: _errors),
            const SizedBox(height: 16),
          ],
          if (_jsonMode) ..._jsonFields() else ..._formFields(accent),
        ],
      ),
    );
  }

  List<Widget> _jsonFields() => [
    OutlinedButton.icon(
      onPressed: _copyRewritePrompt,
      icon: const Icon(Icons.content_copy, size: 18),
      label: const Text('Copy rewrite prompt'),
    ),
    const SizedBox(height: 12),
    TextField(
      controller: _json,
      minLines: 18,
      maxLines: null,
      // 'monospace' resolves only on some platforms, so name real families to
      // fall back to rather than landing on the proportional default.
      style: const TextStyle(
        fontFamily: 'monospace',
        fontFamilyFallback: ['Menlo', 'Consolas', 'DejaVu Sans Mono'],
        fontSize: 13,
        height: 1.4,
      ),
      decoration: const InputDecoration(border: OutlineInputBorder()),
    ),
  ];

  List<Widget> _formFields(Color accent) => [
    TextField(
      controller: _title,
      textCapitalization: TextCapitalization.words,
      decoration: const InputDecoration(
        labelText: 'Title',
        border: OutlineInputBorder(),
      ),
    ),
    const SizedBox(height: 12),
    // Directly under the title, because it is the recipe's face.
    _ImageField(
      controller: _imageUrls,
      store: widget.store,
      onPick: _pickImage,
    ),
    const SizedBox(height: 12),
    Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 120,
          child: TextField(
            controller: _servings,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: const InputDecoration(
              labelText: 'Serves',
              border: OutlineInputBorder(),
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: TextField(
            controller: _tags,
            decoration: const InputDecoration(
              labelText: 'Tags',
              helperText: 'Commas between',
              border: OutlineInputBorder(),
            ),
          ),
        ),
      ],
    ),
    const SizedBox(height: 12),
    // Up here rather than at the foot of the form, because this is where it
    // prints: above the ingredients, the way a cookbook sets a headnote.
    TextField(
      controller: _notes,
      minLines: 2,
      maxLines: 5,
      decoration: const InputDecoration(
        labelText: 'Notes',
        helperText: 'Where it comes from, when to make it, what to swap',
        border: OutlineInputBorder(),
      ),
    ),

    _SectionHeading(label: 'Ingredients', count: _ingredients.length),
    for (final (index, draft) in _ingredients.indexed)
      _IngredientRow(
        key: ObjectKey(draft),
        draft: draft,
        onRemove: () => _removeIngredient(index),
        // The name is what step text refers to, so a rename has to move the
        // references with it and repaint the insert chips.
        onNameChanged: () => setState(_applyRenames),
        // The density field only exists for units that can convert, so the
        // row has to rebuild when the unit changes.
        onUnitChanged: () => setState(() {}),
      ),
    _AddButton(label: 'Add ingredient', onPressed: _addIngredient),

    _SectionHeading(label: 'Steps', count: _steps.length),
    for (final (index, draft) in _steps.indexed)
      _StepCard(
        key: ObjectKey(draft),
        draft: draft,
        number: index + 1,
        accent: accent,
        names: _labels(),
        onRemove: () => _removeStep(index),
        onToggle: () => setState(() => draft.expanded = !draft.expanded),
      ),
    _AddButton(label: 'Add step', onPressed: _addStep),

  ];
}

/// The recipe's photo: where it came from, and what it looks like.
///
/// Its own widget listening to the controller, rather than driving the editor's
/// `setState`, for the same reason [_UnitField] is one: a keystroke here should
/// repaint a 72px thumbnail, not a form holding twenty text fields.
class _ImageField extends StatefulWidget {
  final TextEditingController controller;
  final RecipeStore store;
  final VoidCallback onPick;

  const _ImageField({
    required this.controller,
    required this.store,
    required this.onPick,
  });

  @override
  State<_ImageField> createState() => _ImageFieldState();
}

class _ImageFieldState extends State<_ImageField> {
  ImageChain? _chain;
  List<String>? _chainUrls;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_refresh);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _restart();
  }

  @override
  void dispose() {
    widget.controller.removeListener(_refresh);
    _chain?.dispose();
    super.dispose();
  }

  void _refresh() {
    setState(() {});
    _restart();
  }

  List<String> get _urls => [
    for (final url in widget.controller.text.split('\n'))
      if (url.trim().isNotEmpty) url.trim(),
  ];

  /// The same chain the detail screen runs, so the preview and the hero can
  /// never disagree about which url wins.
  // ponytail: restarts as you type, so hand-typing a url resolves each partial
  // form of it. imageFor rejects anything not yet https, which caps the waste —
  // debounce if it ever matters.
  void _restart() {
    final urls = _urls;
    if (listEquals(_chainUrls, urls)) return;
    _chain?.dispose();
    _chainUrls = urls;
    _chain = ImageChain(urls, widget.store, () {
      if (mounted) setState(() {});
    });
    _chain!.resolve(createLocalImageConfiguration(context));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final urls = _urls;
    final winner = _chain?.winner;
    final image = imageFor(winner, widget.store);
    return Row(
      children: [
        // Tap the picture to change the picture — no separate button, and the
        // badge is what says so, since there is no hover on a phone. The same
        // move the detail screen's ingredient rows make.
        Tooltip(
          message: 'Choose photo',
          child: InkWell(
            onTap: widget.onPick,
            borderRadius: BorderRadius.circular(pillRadius),
            child: Container(
              width: 72,
              height: 72,
              alignment: Alignment.center,
              clipBehavior: Clip.antiAlias,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(pillRadius),
                color: glassFill(context),
                border: Border.all(color: glassRim(context)),
              ),
              // The preview is the reason this lives in the form at all: urls
              // that all lead nowhere show themselves here, before saving,
              // instead of turning up later as a recipe with no photo.
              child: Stack(
                fit: StackFit.expand,
                children: [
                  if (image case final image?)
                    Image(
                      image: image,
                      fit: BoxFit.cover,
                      errorBuilder: (context, _, _) => const SizedBox.shrink(),
                    )
                  else
                    Icon(
                      urls.isEmpty
                          ? Icons.add_a_photo_outlined
                          : Icons.broken_image_outlined,
                      color: urls.isEmpty
                          ? theme.colorScheme.onSurfaceVariant
                          : theme.colorScheme.error,
                    ),
                  if (image != null)
                    Positioned(
                      right: 0,
                      bottom: 0,
                      child: ColoredBox(
                        color: theme.colorScheme.surface.withValues(
                          alpha: 0.75,
                        ),
                        child: const Padding(
                          padding: EdgeInsets.all(3),
                          child: Icon(Icons.edit_outlined, size: 13),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: TextField(
            controller: widget.controller,
            keyboardType: TextInputType.multiline,
            minLines: 1,
            maxLines: 3,
            decoration: InputDecoration(
              labelText: 'Images',
              // Doubles as the source line: the host the detail screen will
              // credit under the photo, so what wins here is what wins there.
              helperText:
                  creditFor(winner) ??
                  (urls.isEmpty
                      ? 'Optional — one link per line, or tap'
                      : 'None of these loaded'),
              isDense: true,
              border: const OutlineInputBorder(),
            ),
          ),
        ),
      ],
    );
  }
}

/// "step 2", "steps 1 and 3", "steps 1, 2 and 4".
String _stepList(List<int> numbers) {
  final label = numbers.length == 1 ? 'step' : 'steps';
  if (numbers.length == 1) return '$label ${numbers.single}';
  final head = numbers.sublist(0, numbers.length - 1).join(', ');
  return '$label $head and ${numbers.last}';
}

// ------------------------------------------------------------------- drafts

/// One editable ingredient. Controllers rather than a rebuilt [Ingredient] per
/// keystroke, so the cursor stays where the user put it.
class _IngredientDraft {
  final String id;
  final TextEditingController name;
  final TextEditingController amount;
  final TextEditingController density;
  Unit? unit;

  /// The label the step text currently refers to this ingredient by — the
  /// name, or `name #id` where it shares that name. Empty for one just added,
  /// which no step can be referencing yet.
  String knownAs;

  _IngredientDraft({
    required this.id,
    required String name,
    required String amount,
    String density = '',
    this.knownAs = '',
    this.unit,
  }) : name = TextEditingController(text: name),
       amount = TextEditingController(text: amount),
       density = TextEditingController(text: density);

  factory _IngredientDraft.from(Ingredient ingredient, String knownAs) =>
      _IngredientDraft(
        id: ingredient.id,
        knownAs: knownAs,
        name: ingredient.name,
        amount: formatAmount(ingredient.amount),
        density: ingredient.densityGPerMl == null
            ? ''
            : formatAmount(ingredient.densityGPerMl!),
        unit: ingredient.unit,
      );

  factory _IngredientDraft.blank(String id) =>
      _IngredientDraft(id: id, name: '', amount: '');

  void dispose() {
    name.dispose();
    amount.dispose();
    density.dispose();
  }
}

class _StepDraft {
  final String id;
  final TextEditingController title;
  final _RefTextController content;
  final TextEditingController timer;
  bool expanded;

  _StepDraft({
    required this.id,
    required String title,
    required String content,
    required String timer,
    this.expanded = false,
  }) : title = TextEditingController(text: title),
       content = _RefTextController(text: content),
       timer = TextEditingController(text: timer);

  factory _StepDraft.from(RecipeStep step, List<Ingredient> ingredients) =>
      _StepDraft(
        id: step.id,
        title: step.title,
        // Ids in, names out: nobody edits {0001} by hand.
        content: toDisplayRefs(step.content, ingredients),
        timer: step.timerSeconds == null
            ? ''
            // Minutes with a decimal, so a 45 s timer round-trips as 0.75
            // rather than rounding away to nothing.
            : formatAmount(step.timerSeconds! / 60),
      );

  factory _StepDraft.blank(String id) =>
      _StepDraft(id: id, title: '', content: '', timer: '', expanded: true);

  int? get seconds {
    final minutes = double.tryParse(timer.text.trim());
    if (minutes == null) return null;
    final value = (minutes * 60).round();
    return value > 0 ? value : null;
  }

  void dispose() {
    title.dispose();
    content.dispose();
    timer.dispose();
  }
}

/// Paints `[bread flour]` in the recipe's own accent so a reference reads as a
/// token rather than as brackets someone forgot to delete.
///
/// Styling only — the span text stays character-for-character identical to the
/// field's text. Substituting a name for the id here instead would change the
/// length and drift the cursor and selection.
class _RefTextController extends TextEditingController {
  _RefTextController({super.text});

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    final refStyle = (style ?? const TextStyle()).copyWith(
      color: tagAccent(context, const []),
      fontWeight: FontWeight.w600,
    );
    final spans = <TextSpan>[];
    var index = 0;
    for (final match in nameRefPattern.allMatches(text)) {
      if (match.start > index) {
        spans.add(TextSpan(text: text.substring(index, match.start)));
      }
      spans.add(TextSpan(text: match[0], style: refStyle));
      index = match.end;
    }
    if (index < text.length) {
      spans.add(TextSpan(text: text.substring(index)));
    }
    return TextSpan(style: style, children: spans);
  }
}

// -------------------------------------------------------------------- pieces

class _SectionHeading extends StatelessWidget {
  final String label;
  final int count;

  const _SectionHeading({required this.label, required this.count});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 28, bottom: 10),
      child: Row(
        children: [
          Text(label, style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(width: 8),
          Text('$count', style: Theme.of(context).textTheme.bodySmall),
        ],
      ),
    );
  }
}

class _AddButton extends StatelessWidget {
  final String label;
  final VoidCallback onPressed;

  const _AddButton({required this.label, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: TextButton.icon(
        onPressed: onPressed,
        icon: const Icon(Icons.add, size: 18),
        label: Text(label),
      ),
    );
  }
}

/// Name on its own line, amount and unit under it: at phone width three fields
/// in one row squeezes the name down to a few characters.
class _IngredientRow extends StatelessWidget {
  final _IngredientDraft draft;
  final VoidCallback onRemove;
  final VoidCallback onNameChanged;
  final VoidCallback onUnitChanged;

  const _IngredientRow({
    super.key,
    required this.draft,
    required this.onRemove,
    required this.onNameChanged,
    required this.onUnitChanged,
  });

  @override
  Widget build(BuildContext context) {
    return GlassPanel(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 4, 12),
        child: Column(
          children: [
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: draft.name,
                    onChanged: (_) => onNameChanged(),
                    decoration: const InputDecoration(
                      labelText: 'Ingredient',
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                IconButton(
                  onPressed: onRemove,
                  tooltip: 'Remove ingredient',
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: draft.amount,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      inputFormatters: [
                        FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
                      ],
                      decoration: const InputDecoration(
                        labelText: 'Amount',
                        isDense: true,
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _UnitField(draft: draft, onChanged: onUnitChanged),
                  ),
                ],
              ),
            ),
            // Its own line rather than a third column: three fields across a
            // phone leaves none of them readable. Absent entirely for units
            // that could never convert, where a density means nothing.
            if (unitConverts(draft.unit)) ...[
              const SizedBox(height: 10),
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: TextField(
                  controller: draft.density,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  inputFormatters: [
                    FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
                  ],
                  decoration: const InputDecoration(
                    labelText: 'Density (g/ml)',
                    helperText:
                        'Optional — lets this switch between weight '
                        'and volume',
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Its own widget so picking a unit rebuilds one row rather than the whole
/// editor, which would take every other field's focus with it.
class _UnitField extends StatefulWidget {
  final _IngredientDraft draft;
  final VoidCallback onChanged;

  const _UnitField({required this.draft, required this.onChanged});

  @override
  State<_UnitField> createState() => _UnitFieldState();
}

class _UnitFieldState extends State<_UnitField> {
  @override
  Widget build(BuildContext context) {
    return DropdownButtonFormField<Unit?>(
      initialValue: widget.draft.unit,
      isExpanded: true,
      decoration: const InputDecoration(
        labelText: 'Unit',
        isDense: true,
        border: OutlineInputBorder(),
      ),
      items: [
        const DropdownMenuItem(value: null, child: Text('whole')),
        for (final unit in Unit.values)
          DropdownMenuItem(value: unit, child: Text(unitLabel(unit))),
      ],
      onChanged: (unit) {
        setState(() => widget.draft.unit = unit);
        widget.onChanged();
      },
    );
  }
}

/// Collapsed to a single line until tapped, so a long recipe stays scannable.
class _StepCard extends StatelessWidget {
  final _StepDraft draft;
  final int number;
  final Color accent;
  final List<String> names;
  final VoidCallback onRemove;
  final VoidCallback onToggle;

  const _StepCard({
    super.key,
    required this.draft,
    required this.number,
    required this.accent,
    required this.names,
    required this.onRemove,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return GlassPanel(
      margin: const EdgeInsets.only(bottom: 10),
      child: Column(
        children: [
          InkWell(
            onTap: onToggle,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
              child: Row(
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
                    child: Text(
                      draft.title.text.isEmpty
                          ? 'Untitled step'
                          : draft.title.text,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleMedium,
                    ),
                  ),
                  IconButton(
                    onPressed: onRemove,
                    tooltip: 'Remove step',
                    icon: const Icon(Icons.close),
                  ),
                  Icon(draft.expanded ? Icons.expand_less : Icons.expand_more),
                ],
              ),
            ),
          ),
          if (draft.expanded)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TextField(
                    controller: draft.title,
                    decoration: const InputDecoration(
                      labelText: 'Title',
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: draft.content,
                    minLines: 3,
                    maxLines: 8,
                    decoration: const InputDecoration(
                      labelText: 'What to do',
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 8),
                  _InsertBar(names: names, controller: draft.content),
                  const SizedBox(height: 10),
                  TextField(
                    controller: draft.timer,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    inputFormatters: [
                      FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
                    ],
                    decoration: const InputDecoration(
                      labelText: 'Timer (minutes)',
                      helperText: 'Empty if the step involves no waiting',
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// The row of ingredients a step can drop into its text. Tapping one inserts
/// it at the cursor, which is the whole reason nobody has to know that a
/// reference is really `{0001}` underneath.
class _InsertBar extends StatelessWidget {
  final List<String> names;
  final TextEditingController controller;

  const _InsertBar({required this.names, required this.controller});

  void _insert(String name) {
    final value = controller.value;
    final selection = value.selection;
    // A field that has never held the cursor reports an invalid selection.
    final start = selection.isValid ? selection.start : value.text.length;
    final end = selection.isValid ? selection.end : value.text.length;
    final inserted = '[$name]';
    controller.value = TextEditingValue(
      text: value.text.replaceRange(start, end, inserted),
      selection: TextSelection.collapsed(offset: start + inserted.length),
    );
  }

  @override
  Widget build(BuildContext context) {
    final usable = [
      for (final name in names)
        if (name.isNotEmpty) name,
    ];
    if (usable.isEmpty) return const SizedBox.shrink();
    return Align(
      alignment: Alignment.centerLeft,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            for (final name in usable)
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: ActionChip(
                  avatar: const Icon(Icons.add, size: 16),
                  label: Text(name),
                  onPressed: () => _insert(name),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
