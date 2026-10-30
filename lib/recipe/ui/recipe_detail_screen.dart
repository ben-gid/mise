import 'dart:async';

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../recipe_image.dart';
import '../recipe_models.dart';
import '../recipe_parser.dart';
import '../recipe_scaling.dart';
import '../recipe_server.dart';
import '../recipe_store.dart';
import '../recipe_sync.dart';
import '../recipe_timers.dart';
import 'cook_log.dart';
import 'glass.dart';
import 'writing.dart' show verbsFor;
import 'pro_screen.dart' show writeOrUpgrade;
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

class _RecipeDetailScreenState extends State<RecipeDetailScreen>
    with SingleTickerProviderStateMixin {
  /// The version on screen. Editing swaps these for the newly saved version
  /// in place, rather than pushing another copy of this screen.
  late String _id = widget.id;
  late Recipe _recipe = widget.recipe;

  /// What the stepper shows: servings, or loaves for a recipe that makes them.
  late int _servings = baseCount(widget.recipe);

  /// Ingredients tapped into their other dimension. Deliberately not
  /// persisted — this is "my scale is dirty, show me cups", not a preference.
  final _flipped = <String>{};

  /// Every time this version was cooked, newest first.
  List<CookEntry> _entries = const [];

  /// The recipe's photos, tried in order until one loads. Null until the first
  /// [didChangeDependencies], which is the earliest an ImageConfiguration
  /// exists to resolve against.
  ImageChain? _photos;

  /// What [_photos] was built for, so a theme or metrics change re-entering
  /// [didChangeDependencies] doesn't restart the chain and re-open a hero that
  /// has already closed. Both halves, because an edit that fixes a useless
  /// `image_query` leaves the urls untouched — watching only those would leave
  /// the old photo up.
  List<String>? _photoUrls;
  String? _photoQuery;

  /// Guards [_keepFoundPhoto] against firing twice before its write lands —
  /// the chain calls back more than once on the way to a winner.
  bool _keeping = false;

  /// Eases the hero shut when every url has failed. Finite and runs at most
  /// once per recipe, so `pumpAndSettle` still returns (see CLAUDE.md).
  late final _close = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 200),
  );

  @override
  void initState() {
    super.initState();
    // Never cooked is the default state, so there is nothing to show while
    // this resolves — no spinner, which would hang pumpAndSettle.
    _loadEntries();
    pulled.addListener(_onPulled);
  }

  /// Sync landed something from another phone while this is open: a cook for
  /// this version, or a newer version of the recipe, which moves the screen
  /// onto it the way an edit made here would.
  Future<void> _onPulled() async {
    final newest = await widget.store.newest(_id);
    if (!mounted) return;
    if (newest != null && newest.$1 != _id) _adopt(newest);
    await _loadEntries();
  }

  Future<void> _loadEntries() async {
    final entries = await widget.store.entries(_id);
    if (mounted) setState(() => _entries = entries);
  }

  /// Opens the entry dialog: a new cook for [existing] null, prefilled with
  /// today and the servings on screen, otherwise that entry to edit or delete.
  Future<void> _logCook([CookEntry? existing]) async {
    final now = DateTime.now();
    final result = await showDialog<_EntryResult>(
      context: context,
      builder: (_) => _EntryDialog(
        entry:
            existing ??
            (
              id: now.microsecondsSinceEpoch.toString(),
              date: now,
              servings: _servings,
              stars: 0,
              note: '',
            ),
        isNew: existing == null,
        fallbackServings: baseCount(_recipe),
        makes: _recipe.makes,
        accent: Theme.of(context).colorScheme.primary,
      ),
    );
    if (result == null) return;
    if (result.delete) {
      await widget.store.deleteEntry(_id, result.entry.id);
    } else {
      await widget.store.saveEntry(_id, result.entry);
    }
    await _loadEntries();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _startPhotos();
  }

  /// Points the chain at whatever recipe is on screen, if it isn't already.
  ///
  /// Called again from [_adopt]: an edit that fixes a dead url has to reopen
  /// the hero, not leave it shut on the previous version's failure.
  void _startPhotos() {
    if (listEquals(_photoUrls, _recipe.imageUrls) &&
        _photoQuery == _recipe.imageQuery) {
      return;
    }
    _photos?.dispose();
    _photoUrls = _recipe.imageUrls;
    _photoQuery = _recipe.imageQuery;
    // Open for a recipe that carries urls — the first is optimistically the
    // winner, so the photo is there on the first frame. Shut for one that
    // carries none: the Wikipedia fallback is a round trip away, and a hero
    // that opened empty and shut again would flicker on every dish the lookup
    // misses. It eases *open* instead, on the callback below.
    _close.value = _recipe.imageUrls.isEmpty ? 1 : 0;
    _photos = ImageChain(
      _recipe.imageUrls,
      widget.store,
      () {
        if (!mounted) return;
        setState(() {});
        if (_photos?.exhausted ?? false) {
          _close.forward();
        } else if (_photos?.winner != null) {
          // A no-op for a recipe that started open, which is every recipe with
          // urls of its own.
          _close.reverse();
          _keepFoundPhoto();
        }
      },
      // Always, not only as a rescue for urls that failed: the import prompt
      // tells the model to leave image_urls alone, so a recipe with no urls at
      // all is the common case and the one most in need of a photo.
      title: _recipe.title,
      query: _recipe.imageQuery,
    );
    _photos!.resolve(createLocalImageConfiguration(context));
  }

  /// Writes down the photo the search found, the first time it finds one.
  ///
  /// Only a search result, never a Wikipedia stand-in — [winnerFromSearch] is
  /// the difference, and pinning a recipe to the plain fallback is what this
  /// change exists to stop. Only when the recipe has no photo of its own, so a
  /// deliberate pick is never overwritten.
  ///
  /// The point is not the pixels, which are cached anyway: it is that the list
  /// row and the next cold start show this photo without spending the search
  /// again, and that the recipe stops depending on a memo that dies with the
  /// process. It cannot loop — once this lands, `image_urls` is no longer empty
  /// and the rebuilt chain's winner comes from there rather than from a search.
  Future<void> _keepFoundPhoto() async {
    if (_keeping || _recipe.imageUrls.isNotEmpty) return;
    final found = _photos?.winnerFromSearch;
    if (found == null) return;
    _keeping = true;
    try {
      await _keepStockPhoto(found);
    } finally {
      _keeping = false;
    }
  }

  /// [_setPhoto] for a search result: with its photographer, and with the
  /// ping Unsplash asks for when a photo is kept rather than just shown.
  Future<void> _keepStockPhoto(StockPhoto photo) {
    unawaited(keptStockPhoto(photo));
    return _setPhoto(photo.url, photo.credit);
  }

  /// Pins [url] onto the recipe, in place, with [credit] — always both, so a
  /// credit can never outlive the photo it names.
  ///
  /// [RecipeStore.save] and not `saveVersion`: the id is
  /// `<createdAtMillis>-<title-slug>` and neither half moves here, so this
  /// rewrites the same file under the same id. That is what keeps the cook log
  /// attached — it is keyed by id — and what keeps "I picked a nicer
  /// picture" out of the version history, where it would sit between two real
  /// edits pretending to be one.
  ///
  /// And deliberately not [_adopt], which clears the log. [_adopt] is right
  /// to: every path into it mints a new id, and leaving five stars on a version
  /// nobody has cooked would be a lie. Here there is no new version to lie
  /// about.
  ///
  /// Unvalidated, like the list screen's Undo, which is the other caller that
  /// re-saves a recipe that already parsed once. The url came from our own
  /// search or our own picker, not from a model.
  Future<void> _setPhoto(String url, ImageCredit? credit) async {
    // Recipe has no copyWith; a modified copy goes back through the map.
    final updated = Recipe.fromJson({
      ..._recipe.toJson(),
      'image_urls': [url],
      'image_credit': credit?.toJson(),
    });
    await widget.store.save(updated);
    if (!mounted) return;
    setState(() => _recipe = updated);
    _startPhotos();
  }

  /// Opens the photo picker: the stock photos for this dish, plus the cook's
  /// own camera.
  ///
  /// The search is awaited *before* the sheet opens rather than inside it. A
  /// spinner in a modal is an indefinite animation and `pumpAndSettle` never
  /// returns on one (CLAUDE.md), and there is nothing to wait for anyway — the
  /// hero ran this exact query on the way in and [stockPhotos] is memoised.
  ///
  /// Falls back to the title when a recipe carries no `image_query`. Those are
  /// the wrong words to spend a chain link on — "Nonna's Sunday gravy" matches
  /// nothing in a photo library — but the right ones to hand a human who can
  /// look at what comes back and judge.
  Future<void> _pickPhoto() async {
    final photos = await stockPhotos(_recipe.imageQuery ?? _recipe.title);
    if (!mounted) return;
    final picked = await showModalBottomSheet<Object>(
      context: context,
      isScrollControlled: true,
      // The sheet's own Material stays clear so frost is the only surface;
      // its drag handle would sit on nothing, so the sheet draws its own.
      backgroundColor: Colors.transparent,
      showDragHandle: false,
      builder: (context) => frost(
        context: context,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
        ),
        tint: Theme.of(
          context,
        ).colorScheme.surface.withValues(alpha: frostAlpha),
        child: _PhotoSheet(photos: photos, store: widget.store),
      ),
    );
    if (picked == null || !mounted) return;
    // The device photo stays the editor's job: it writes a file and needs the
    // parser, and a second copy of that path here is what CLAUDE.md warns off.
    // It costs a version, where a stock pick does not — an asymmetry worth
    // less than a duplicated picker.
    if (picked == _ownPhoto) return _edit(pickImage: true);
    if (picked is StockPhoto) await _keepStockPhoto(picked);
  }

  /// Flips one ingredient between weight and volume, for the length of this
  /// visit. Ingredients with no density say so rather than doing nothing —
  /// there is no hover on a phone, so this is the tooltip.
  void _toggle(Ingredient ingredient) {
    if (!canConvert(ingredient)) {
      // Two different failures, and only one of them has a fix: a countable
      // item or a pinch has no density field in the editor to go and fill in.
      final message = unitConverts(ingredient.unit)
          ? 'No density for ${ingredient.name}. Add one in Edit to switch it.'
          : 'No fixed size for ${ingredient.name} — nothing to convert.';
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
      return;
    }
    // Block body, and Set.remove's return doubles as the membership test.
    setState(() {
      if (!_flipped.remove(ingredient.id)) _flipped.add(ingredient.id);
    });
  }

  /// Shows [saved] as the current version. The cook log is cleared rather than
  /// carried over: each version keeps its own, so leaving the old entries on
  /// screen would imply this version had already been cooked.
  void _adopt(SavedRecipe saved) {
    setState(() {
      // An edit that gave it loaves, or changed how many, leaves the old
      // count meaning something else.
      if (baseCount(saved.$2) != baseCount(_recipe)) {
        _servings = baseCount(saved.$2);
      }
      _id = saved.$1;
      _recipe = saved.$2;
      _entries = const [];
    });
    _startPhotos();
  }

  /// [pickImage] opens straight into the photo picker, which is all the
  /// "Add photo" action is: the editor has held the picker all along, and
  /// routing through it keeps the save going through the parser like every
  /// other edit rather than growing a second save path here.
  Future<void> _edit({bool pickImage = false}) async {
    final saved = await Navigator.push<SavedRecipe>(
      context,
      MaterialPageRoute(
        builder: (_) => RecipeEditScreen(
          id: _id,
          recipe: _recipe,
          store: widget.store,
          parser: widget.parser,
          pickImageOnOpen: pickImage,
        ),
      ),
    );
    if (saved != null && mounted) _adopt(saved);
  }

  /// Has the server make [change] to this recipe, as a new version: the
  /// history diff then says exactly what it did, and Undo these changes takes
  /// it back. True once it is saved, so the box can clear.
  Future<bool> _adapt(String change) async {
    final messenger = ScaffoldMessenger.of(context);
    final Recipe recipe;
    try {
      recipe = widget.parser.parse(
        await writeOrUpgrade(context, [
          'Changing the recipe…',
          ...verbsFor(change),
        ], () => askForRecipe(text: change, base: _recipe.toJson())),
      );
    } on RecipeValidationException catch (e) {
      final count = e.errors.length;
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            'Couldn\'t make that change — the result had $count '
            'problem${count == 1 ? '' : 's'}. Nothing was saved.',
          ),
        ),
      );
      return false;
    } on ServerRecipeException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.message)));
      return false;
    }
    final saved = await widget.store.saveVersion(recipe, parent: _id);
    if (mounted) _adopt(saved);
    return true;
  }

  Future<void> _openHistory() async {
    final restored = await Navigator.push<SavedRecipe>(
      context,
      MaterialPageRoute(
        builder: (_) => RecipeHistoryScreen(
          id: _id,
          store: widget.store,
          parser: widget.parser,
        ),
      ),
    );
    if (restored != null && mounted) _adopt(restored);
  }

  @override
  void dispose() {
    pulled.removeListener(_onPulled);
    _photos?.dispose();
    _close.dispose();
    super.dispose();
  }

  /// Native share sheet, carrying the recipe scaled to the servings on screen.
  Future<void> _share() async {
    // iPad anchors the share popover to a rect; without one it throws. The
    // screen's own box centres it, which is fine for a single app-bar button.
    final box = context.findRenderObject() as RenderBox?;
    await SharePlus.instance.share(
      ShareParams(
        text: formatForSharing(_recipe, _servings, flipped: _flipped),
        subject: _recipe.title,
        sharePositionOrigin: box == null
            ? null
            : box.localToGlobal(Offset.zero) & box.size,
      ),
    );
  }

  /// Ingredients ticked off as they come out of the cupboard. Per visit, like
  /// [_flipped]: a checklist for tonight, not a fact about the recipe.
  final _ready = <String>{};

  void _tick(Ingredient ingredient) {
    setState(() {
      if (!_ready.remove(ingredient.id)) _ready.add(ingredient.id);
    });
  }

  @override
  Widget build(BuildContext context) {
    final recipe = _recipe;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final factor = scaleFactor(recipe, _servings);
    final accent = scheme.primary;
    final timed = recipe.steps.fold(0, (sum, s) => sum + (s.timerSeconds ?? 0));
    final convertible = recipe.ingredients.any(canConvert);

    return GlassScaffold(
      // No `appBar`: the photo has to scroll *under* the bar rather than sit
      // below it, and Scaffold.appBar only takes a PreferredSizeWidget.
      //
      // ponytail: this rebuilds the whole scroll view for the 200ms the hero
      // spends closing. A sliver-typed wrapper if it ever shows up in a trace.
      body: AnimatedBuilder(
        animation: _close,
        builder: (context, _) => CustomScrollView(
          slivers: [
            _hero(context),
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
              sliver: SliverList.list(
                children: [
                  if (recipe.tags.isNotEmpty) ...[
                    _TagLine(tags: recipe.tags),
                    const SizedBox(height: 12),
                  ],
                  // Free to wrap: a toolbar could only ever give it 56px,
                  // which is two lines and a truncation.
                  Text(recipe.title, style: theme.textTheme.headlineMedium),
                  if (recipe.notes case final notes? when notes.isNotEmpty) ...[
                    const SizedBox(height: 14),
                    _Headnote(text: notes),
                  ],
                  const SizedBox(height: 18),
                  _Facts(
                    recipe: recipe,
                    servings: _servings,
                    onServings: (value) => setState(() => _servings = value),
                    timed: timed,
                    entries: _entries,
                  ),
                  const SizedBox(height: 28),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.baseline,
                    textBaseline: TextBaseline.alphabetic,
                    children: [
                      Expanded(
                        child: Text(
                          'Mise en place',
                          style: theme.textTheme.headlineSmall,
                        ),
                      ),
                      Text(
                        _ready.length == recipe.ingredients.length
                            ? 'All ready'
                            : '${_ready.length} of '
                                  '${recipe.ingredients.length} ready',
                        style: weighted(
                          theme.textTheme.bodyMedium,
                          FontWeight.w600,
                        )?.copyWith(color: accent),
                      ),
                    ],
                  ),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          'Tick things off as you get them out.',
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                      // Kept in the row even when there is nothing to reset,
                      // so ticking the first item doesn't shift the list.
                      TextButton(
                        onPressed: _ready.isEmpty
                            ? null
                            : () => setState(_ready.clear),
                        child: const Text('Reset'),
                      ),
                    ],
                  ),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(2),
                    child: LinearProgressIndicator(
                      // Determinate, so it never animates on its own.
                      value: recipe.ingredients.isEmpty
                          ? 0
                          : _ready.length / recipe.ingredients.length,
                      minHeight: 3,
                      backgroundColor: glassRim(context),
                    ),
                  ),
                  for (final ingredient in recipe.ingredients)
                    _IngredientRow(
                      ingredient: ingredient,
                      label: amountLabel(
                        ingredient,
                        factor,
                        flip: _flipped.contains(ingredient.id),
                      ),
                      derived: isDerived(
                        ingredient,
                        flip: _flipped.contains(ingredient.id),
                      ),
                      ready: _ready.contains(ingredient.id),
                      onTick: () => _tick(ingredient),
                      onSwitch: () => _toggle(ingredient),
                    ),
                  if (convertible) ...[
                    const SizedBox(height: 10),
                    Text(
                      'Tap an amount to switch units. Shaded ones are '
                      'converted by density — close, not exact.',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                  const SizedBox(height: 30),
                  Text('Method', style: theme.textTheme.headlineSmall),
                  const SizedBox(height: 4),
                  for (final (index, step) in recipe.steps.indexed)
                    _StepRow(
                      number: index + 1,
                      step: step,
                      timer: timerKey(_id, step.id),
                      recipeTitle: recipe.title,
                      last: index == recipe.steps.length - 1,
                      parts: contentParts(
                        step,
                        recipe,
                        factor,
                        flipped: _flipped,
                      ),
                    ),
                  const SizedBox(height: 30),
                  if (serverRecipesOn) ...[
                    _AdaptBox(onSubmit: _adapt),
                    const SizedBox(height: 30),
                  ],
                ],
              ),
            ),
            SliverToBoxAdapter(
              child: _CookLog(
                entries: _entries,
                makes: recipe.makes,
                source: recipe.source,
                onAdd: _logCook,
                onEdit: _logCook,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// The bar, and the photo behind it when there is one.
  ///
  /// Without any urls this is a plain bar. With them, the photo scrolls up and
  /// the page closes over it as it goes.
  ///
  /// When every url turns out to be dead the hero eases shut and this becomes
  /// the plain bar: a recipe whose photos don't load is a recipe with no photo,
  /// not one wearing generated art in a picture's place.
  Widget _hero(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    // One oval rather than four loose buttons: they are one group of things
    // you do *to* the recipe, and on a photo four separate circles read as
    // four stickers.
    Widget bar({required double overPhoto}) => _Pill(
      overPhoto: overPhoto,
      children: [
        // Unconditional: with a photo search in the chain almost every recipe
        // has *something*, and the case this exists for is that it loaded and
        // is the wrong one.
        IconButton(
          onPressed: _pickPhoto,
          tooltip: 'Choose photo',
          icon: const Icon(Icons.photo_camera_outlined),
        ),
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
          icon: const Icon(Icons.ios_share),
        ),
      ],
    );
    Widget back({required double overPhoto}) => Center(
      child: _Pill(overPhoto: overPhoto, children: const [BackButton()]),
    );

    if (_recipe.imageUrls.isEmpty && _photos?.winner == null) {
      // Nothing on screen and nothing claimed: either the lookup is still out
      // or it missed. A recipe with no photo pays nothing for the feature —
      // and a fallback that arrives late finds the hero shut and opens it.
      return SliverAppBar(
        pinned: true,
        leading: back(overPhoto: 0),
        leadingWidth: 64,
        actions: [bar(overPhoto: 0), const SizedBox(width: 12)],
        flexibleSpace: barPane(context),
      );
    }

    final collapsed = MediaQuery.paddingOf(context).top + kToolbarHeight;
    // Just under half a phone: the photo is the thing you land on, and the
    // ingredients are still one thumb-scroll away. Clamped so a phone in
    // landscape isn't all picture and a tablet gets its extra room.
    final full = (MediaQuery.sizeOf(context).height * 0.42).clamp(260.0, 440.0);
    // Rides _close down to the toolbar when the chain gives up. At the bottom
    // the SliverAppBar is already shaped exactly like the plain one, so there
    // is no second widget to cross-fade into.
    final expanded = full - (full - collapsed) * _close.value;
    final winner = _photos?.winner;

    // SliverLayoutBuilder, not a ScrollController: how far the page has closed
    // over the photo is a function of how far this sliver has scrolled, which
    // layout already knows. The only thing that animates is _close, which is
    // finite (see CLAUDE.md).
    return SliverLayoutBuilder(
      builder: (context, constraints) {
        // Goes to zero as the hero closes, and dividing by it would put a NaN
        // straight into the pane's opacity.
        final span = expanded - collapsed;
        final open = span <= 0
            ? 0.0
            : (1 - constraints.scrollOffset / span).clamp(0.0, 1.0);
        return SliverAppBar(
          pinned: true,
          expandedHeight: expanded,
          backgroundColor: Colors.transparent,
          foregroundColor: scheme.onSurface,
          // Status bar icons sit on the photo until the page covers it.
          systemOverlayStyle: open > 0.5 || dark
              ? SystemUiOverlayStyle.light
              : SystemUiOverlayStyle.dark,
          leading: back(overPhoto: open),
          leadingWidth: 64,
          actions: [
            bar(overPhoto: open),
            const SizedBox(width: 12),
          ],
          flexibleSpace: Stack(
            fit: StackFit.expand,
            children: [
              FlexibleSpaceBar(
                // No `title`: the recipe's name is set in the page body, where
                // it can wrap instead of ellipsising.
                background: _HeroImage(
                  image: imageFor(winner, widget.store),
                  // The url that actually loaded, not the one ranked first.
                  credit: creditFor(winner),
                  // Only while the photo it names is the one on screen: a
                  // credit under somebody else's picture is worse than none.
                  photographer: winner == _recipe.imageUrls.firstOrNull
                      ? _recipe.imageCredit
                      : null,
                ),
              ),
              // Decoration only, and on top: a DecoratedBox hit-tests even
              // when transparent, which swallowed taps on the photo credit.
              IgnorePointer(child: barPane(context, opacity: 1 - open)),
            ],
          ),
        );
      },
    );
  }
}

/// One line for asking the server to change the recipe: "make it vegetarian",
/// "halve the sugar". Under the method, where it is in reach once the recipe
/// has been read and out of the way while it is being cooked.
class _AdaptBox extends StatefulWidget {
  final Future<bool> Function(String change) onSubmit;

  const _AdaptBox({required this.onSubmit});

  @override
  State<_AdaptBox> createState() => _AdaptBoxState();
}

class _AdaptBoxState extends State<_AdaptBox> {
  final _change = TextEditingController();

  @override
  void dispose() {
    _change.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final change = _change.text.trim();
    if (change.isEmpty) return;
    FocusScope.of(context).unfocus();
    if (await widget.onSubmit(change) && mounted) _change.clear();
  }

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: _change,
      textInputAction: TextInputAction.send,
      onSubmitted: (_) => _submit(),
      decoration: InputDecoration(
        labelText: 'Change this recipe',
        hintText: 'Make it vegetarian',
        suffixIcon: IconButton(
          onPressed: _submit,
          tooltip: 'Change it',
          icon: const Icon(Icons.auto_awesome_outlined),
        ),
      ),
    );
  }
}

/// Glass over a photo, the page's wash once the page has covered it.
class _Pill extends StatelessWidget {
  /// 1 sitting on the photo, 0 on the plain bar; anything between while the
  /// hero closes.
  final double overPhoto;
  final List<Widget> children;

  const _Pill({required this.overPhoto, required this.children});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return frost(
      context: context,
      shape: const StadiumBorder(),
      tint: Color.lerp(
        glassFill(context),
        scheme.surface.withValues(alpha: frostAlpha),
        overPhoto,
      )!,
      lift: overPhoto > 0,
      child: Row(mainAxisSize: MainAxisSize.min, children: children),
    );
  }
}

/// The photo, a wash at its foot, and the line saying where it came from.
class _HeroImage extends StatelessWidget {
  /// Null once every url has failed. The hero is on its way shut by then, so
  /// there is nothing to put in the picture's place.
  final ImageProvider? image;
  final String? credit;
  final ImageCredit? photographer;

  const _HeroImage({
    required this.image,
    required this.credit,
    required this.photographer,
  });

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        if (image case final image?)
          Image(
            image: image,
            fit: BoxFit.cover,
            // The chain owns the fallback, so a failure here just yields and
            // lets it move to the next url — never a red box.
            errorBuilder: (context, _, _) => const SizedBox.shrink(),
            // Deliberately no loadingBuilder. A spinner here is an indefinite
            // animation, and pumpAndSettle never returns on one (CLAUDE.md).
          ),
        const DecoratedBox(decoration: BoxDecoration(gradient: heroScrim)),
        if (photographer case final photographer?)
          Positioned(
            left: 4,
            right: 4,
            bottom: 2,
            child: _PhotographerCredit(photographer),
          )
        else if (credit case final credit?)
          Positioned(left: 16, right: 16, bottom: 14, child: _Credit(credit)),
      ],
    );
  }
}

/// Where the picture came from. It answers "is this the dish, or a stock
/// photo?" without competing with anything. White: it sits on the scrim.
class _Credit extends StatelessWidget {
  final String text;

  const _Credit(this.text);

  @override
  Widget build(BuildContext context) {
    final ink = Colors.white.withValues(alpha: 0.85);
    return Row(
      children: [
        Icon(Icons.photo_camera_outlined, size: 13, color: ink),
        const SizedBox(width: 6),
        Flexible(
          child: Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(
              context,
            ).textTheme.labelSmall?.copyWith(color: ink, letterSpacing: 0.6),
          ),
        ),
      ],
    );
  }
}

/// "Photo by Jane Doe on Unsplash", word for word what Unsplash's guidelines
/// recommend: the photographer and Unsplash each a link. Two buttons rather
/// than one line with tap spans, so each gets a finger-sized target on a phone.
class _PhotographerCredit extends StatelessWidget {
  final ImageCredit credit;

  const _PhotographerCredit(this.credit);

  @override
  Widget build(BuildContext context) {
    final ink = Colors.white.withValues(alpha: 0.85);
    final style = Theme.of(
      context,
    ).textTheme.labelSmall?.copyWith(color: ink, letterSpacing: 0.6);
    Widget link(String text, String url) => TextButton(
      onPressed: () =>
          launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication),
      style: TextButton.styleFrom(
        foregroundColor: ink,
        padding: const EdgeInsets.symmetric(horizontal: 4),
        minimumSize: const Size(0, 44),
        textStyle: style?.copyWith(decoration: TextDecoration.underline),
      ),
      child: Text(text, maxLines: 1, overflow: TextOverflow.ellipsis),
    );
    return Row(
      children: [
        const SizedBox(width: 12),
        Icon(Icons.photo_camera_outlined, size: 13, color: ink),
        const SizedBox(width: 6),
        Text('Photo by', style: style),
        Flexible(child: link(credit.name, credit.url)),
        Text('on', style: style),
        link('Unsplash', _unsplashHome),
      ],
    );
  }
}

const _unsplashHome =
    'https://unsplash.com/?utm_source=mise&utm_medium=referral';

/// "bread · vegetarian · make-ahead", above the name. One Text per tag so
/// each stays a word of its own for a screen reader.
class _TagLine extends StatelessWidget {
  final List<String> tags;

  const _TagLine({required this.tags});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = weighted(
      theme.textTheme.labelMedium,
      FontWeight.w600,
    )?.copyWith(color: theme.colorScheme.primary, letterSpacing: 1.1);
    return Wrap(
      runSpacing: 4,
      children: [
        for (final (index, tag) in tags.indexed) ...[
          if (index > 0) Text('  ·  ', style: style),
          Text(tag, style: style),
        ],
      ],
    );
  }
}

/// The recipe's headnote, printed above everything else the way a cookbook
/// prints one: where the dish came from, when to make it, what can be swapped.
///
/// Cut to [_maxLines] with a More button, because a four-sentence note would
/// otherwise push the servings and the first ingredients off a phone screen.
/// The button appears only when the text is really clipped, which depends on
/// the width it was given — so it is measured with a [TextPainter] at that
/// width rather than guessed from the string's length.
class _Headnote extends StatefulWidget {
  final String text;

  const _Headnote({required this.text});

  @override
  State<_Headnote> createState() => _HeadnoteState();
}

class _HeadnoteState extends State<_Headnote> {
  static const _maxLines = 4;

  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = serif(
      21,
      height: 1.32,
      italic: true,
    ).copyWith(color: theme.colorScheme.onSurface.withValues(alpha: 0.86));
    return LayoutBuilder(
      builder: (context, constraints) {
        final painter = TextPainter(
          text: TextSpan(text: widget.text, style: style),
          maxLines: _maxLines,
          textDirection: Directionality.of(context),
          textScaler: MediaQuery.textScalerOf(context),
        )..layout(maxWidth: constraints.maxWidth);
        final clipped = painter.didExceedMaxLines;
        painter.dispose();
        final cut = clipped && !_expanded;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.text,
              style: style,
              // Both, together, or neither: an ellipsis with no maxLines
              // limits the paragraph to a *single* line, so leaving it set
              // while expanded would show one line of a nine-line note.
              maxLines: cut ? _maxLines : null,
              overflow: cut ? TextOverflow.ellipsis : TextOverflow.clip,
            ),
            if (clipped)
              TextButton(
                style: TextButton.styleFrom(
                  padding: EdgeInsets.zero,
                  minimumSize: const Size(48, 40),
                ),
                onPressed: () => setState(() => _expanded = !_expanded),
                child: Text(_expanded ? 'Less' : 'More'),
              ),
          ],
        );
      },
    );
  }
}

/// The strip under the headnote: how many it serves (and the control that
/// changes it), how long the timed steps add up to, and how it has gone.
class _Facts extends StatelessWidget {
  final Recipe recipe;
  final int servings;
  final ValueChanged<int> onServings;

  /// Seconds across every timed step; 0 hides the cell.
  final int timed;
  final List<CookEntry> entries;

  const _Facts({
    required this.recipe,
    required this.servings,
    required this.onServings,
    required this.timed,
    required this.entries,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final rule = BorderSide(color: glassRim(context));
    final stars = headlineStars(entries);
    final label = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final figure = serif(30, height: 1.2);

    Widget cell(String name, Widget value) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(name, style: label),
          SizedBox(height: 44, child: value),
        ],
      ),
    );

    Widget divider() => Container(
      width: 1,
      margin: const EdgeInsets.symmetric(horizontal: 14),
      color: glassRim(context),
    );

    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border(top: rule, bottom: rule),
      ),
      // IntrinsicHeight so the dividers run the strip's full height.
      child: IntrinsicHeight(
        child: Row(
          children: [
            switch (recipe.makes) {
              null => cell(
                'Serves',
                _Stepper(value: servings, onChanged: onServings),
              ),
              final makes => cell(
                switch (servesAt(recipe, servings)) {
                  final serves? => 'Makes · serves $serves',
                  null => 'Makes',
                },
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _Stepper(value: servings, onChanged: onServings),
                    Text(
                      makes.noun(servings),
                      style: theme.textTheme.bodyLarge,
                    ),
                  ],
                ),
              ),
            },
            if (timed > 0) ...[
              divider(),
              Expanded(
                child: cell(
                  'Timed',
                  // "2 h 30 min" is wider than a third of a phone at this
                  // size; shrink it rather than wrap it out of the cell.
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: Text(formatDuration(timed), style: figure),
                  ),
                ),
              ),
            ],
            divider(),
            Expanded(
              child: cell(
                entries.isEmpty ? 'Not made yet' : 'Made ${entries.length}×',
                Row(
                  children: [
                    if (stars > 0) ...[
                      Icon(
                        Icons.star,
                        size: 22,
                        color: theme.colorScheme.primary,
                      ),
                      const SizedBox(width: 4),
                      Text('$stars', style: figure),
                    ] else
                      Text('—', style: figure),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// − n +, with the number set as a figure. Shared by the servings on the page
/// and the servings in the cook dialog.
class _Stepper extends StatelessWidget {
  final int value;
  final ValueChanged<int> onChanged;

  const _Stepper({required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          onPressed: value > 1 ? () => onChanged(value - 1) : null,
          icon: const Icon(Icons.remove),
          color: accent,
          tooltip: 'Fewer',
          visualDensity: VisualDensity.compact,
        ),
        ConstrainedBox(
          constraints: const BoxConstraints(minWidth: 24),
          child: Text(
            '$value',
            textAlign: TextAlign.center,
            style: serif(30, height: 1.2),
          ),
        ),
        IconButton(
          onPressed: () => onChanged(value + 1),
          icon: const Icon(Icons.add),
          color: accent,
          tooltip: 'More',
          visualDensity: VisualDensity.compact,
        ),
      ],
    );
  }
}

/// One line of the mise en place: a tick for "it's out on the counter", then
/// the amount and the name, which tap to switch units.
class _IngredientRow extends StatelessWidget {
  final Ingredient ingredient;
  final String label;
  final bool derived;
  final bool ready;
  final VoidCallback onTick;
  final VoidCallback onSwitch;

  const _IngredientRow({
    required this.ingredient,
    required this.label,
    required this.derived,
    required this.ready,
    required this.onTick,
    required this.onSwitch,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final ink = ready ? scheme.onSurfaceVariant : scheme.onSurface;
    final decoration = ready ? TextDecoration.lineThrough : null;
    // The amount column grows with the reader's text size, but never takes
    // more than a third of the row from the name.
    final amountWidth = MediaQuery.textScalerOf(
      context,
    ).scale(104).clamp(0.0, MediaQuery.sizeOf(context).width / 3);
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: glassRim(context))),
      ),
      child: Row(
        children: [
          // Its own target, so ticking never switches units by accident.
          Semantics(
            checked: ready,
            label: ingredient.name,
            child: InkResponse(
              onTap: onTick,
              radius: 24,
              child: SizedBox(
                width: 44,
                height: 52,
                child: Center(
                  child: AnimatedContainer(
                    // Finite, and only on a tap.
                    duration: const Duration(milliseconds: 120),
                    width: 24,
                    height: 24,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: ready ? scheme.primary : null,
                      border: ready
                          ? null
                          : Border.all(color: scheme.outline, width: 1.5),
                    ),
                    child: ready
                        ? Icon(Icons.check, size: 16, color: scheme.onPrimary)
                        : null,
                  ),
                ),
              ),
            ),
          ),
          Expanded(
            // The whole rest of the line, not just the amount: a bare text run
            // is a target too small for a hand that is also holding a bowl.
            // InkWell rather than a GestureDetector so the row is reachable
            // by keyboard and announced as a button. Every row taps, including
            // the ones that can't switch; those answer with a SnackBar.
            child: InkWell(
              onTap: onSwitch,
              borderRadius: BorderRadius.circular(8),
              child: Ink(
                // Marks an amount computed through a density, not one the
                // reader tapped: a tap back onto the stored unit clears it, and
                // the setting lights a whole recipe at once. Off once ticked —
                // it is about measuring, and that one is measured.
                decoration: BoxDecoration(
                  color: derived && !ready ? herbWash(context) : null,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 52),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
                    child: Row(
                      children: [
                        SizedBox(
                          width: amountWidth,
                          child: _Amount(
                            label: label,
                            color: ready ? ink : scheme.primary,
                            decoration: decoration,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            ingredient.name,
                            style: theme.textTheme.bodyLarge?.copyWith(
                              color: ink,
                              decoration: decoration,
                            ),
                          ),
                        ),
                        if (canConvert(ingredient))
                          Icon(
                            Icons.swap_horiz,
                            size: 18,
                            color: scheme.onSurfaceVariant,
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The signature: live scaling is what this app is for, so the amount wears
/// the accent to mark it as the token the servings stepper moves.
class _Amount extends StatelessWidget {
  final String label;
  final Color color;
  final TextDecoration? decoration;

  const _Amount({required this.label, required this.color, this.decoration});

  @override
  Widget build(BuildContext context) {
    final reduced = MediaQuery.disableAnimationsOf(context);
    return AnimatedSwitcher(
      // Finite, and only ever triggered by the servings stepper. Anything that
      // loops here would hang pumpAndSettle.
      duration: reduced ? Duration.zero : const Duration(milliseconds: 180),
      // Left-aligned in its column rather than centred, the default.
      layoutBuilder: (current, previous) => Stack(
        alignment: Alignment.centerLeft,
        children: [...previous, ?current],
      ),
      child: Text(
        label,
        key: ValueKey(label),
        style: weighted(Theme.of(context).textTheme.bodyLarge, FontWeight.w600)
            ?.copyWith(
              color: color,
              decoration: decoration,
              // Numerals go monospaced, so an amount reads as a measured
              // value rather than a word.
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
      ),
    );
  }
}

class _StepRow extends StatelessWidget {
  final int number;
  final RecipeStep step;
  final bool last;

  /// The step's words with every `{0001}` already scaled and spelled out.
  final List<({String? amount, String text})> parts;

  /// Its [timerKey], and the recipe's name for the notification.
  final String timer;
  final String recipeTitle;

  const _StepRow({
    required this.number,
    required this.step,
    required this.last,
    required this.parts,
    required this.timer,
    required this.recipeTitle,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final strong = weighted(
      theme.textTheme.bodyLarge,
      FontWeight.w600,
    )?.copyWith(color: scheme.primary);
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 14),
      decoration: BoxDecoration(
        border: last
            ? null
            : Border(bottom: BorderSide(color: glassRim(context))),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 34,
            child: Text(
              '$number',
              style: serif(38, height: 0.95).copyWith(color: scheme.primary),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(step.title, style: theme.textTheme.titleMedium),
                const SizedBox(height: 4),
                // Each ingredient in the accent and in weight, amount and name
                // alike, so a step can be read for what goes in at a glance.
                Text.rich(
                  TextSpan(
                    children: [
                      for (final part in parts)
                        if (part.amount case final amount?) ...[
                          TextSpan(
                            text: amount,
                            style: strong?.copyWith(
                              fontFeatures: const [
                                FontFeature.tabularFigures(),
                              ],
                            ),
                          ),
                          TextSpan(text: ' ${part.text}', style: strong),
                        ] else
                          TextSpan(text: part.text),
                    ],
                  ),
                  style: theme.textTheme.bodyLarge,
                ),
                if (step.timerSeconds case final seconds?) ...[
                  const SizedBox(height: 10),
                  _StepTimer(
                    timer: timer,
                    length: Duration(seconds: seconds),
                    stepTitle: step.title,
                    recipeTitle: recipeTitle,
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// A step's timer: a Start button, then the time left counting down, then
/// Done. The countdown is read off [timers]' end time each second, so it is
/// right after the phone has been locked and the app suspended.
class _StepTimer extends StatefulWidget {
  final String timer;
  final Duration length;
  final String stepTitle;
  final String recipeTitle;

  const _StepTimer({
    required this.timer,
    required this.length,
    required this.stepTitle,
    required this.recipeTitle,
  });

  @override
  State<_StepTimer> createState() => _StepTimerState();
}

class _StepTimerState extends State<_StepTimer> {
  /// Ticks only while this step's timer runs. An indefinite animation would
  /// hang `pumpAndSettle` (CLAUDE.md), so idle and finished timers never tick.
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    timers.addListener(_sync);
    _sync();
  }

  @override
  void dispose() {
    timers.removeListener(_sync);
    _tick?.cancel();
    super.dispose();
  }

  DateTime? get _end => timers.value[widget.timer];

  /// Starts or stops ticking to match [timers], and repaints.
  void _sync() {
    final end = _end;
    final running = end != null && end.isAfter(DateTime.now());
    if (running && _tick == null) {
      _tick = Timer.periodic(const Duration(seconds: 1), (_) => _sync());
    } else if (!running) {
      _tick?.cancel();
      _tick = null;
    }
    if (mounted) setState(() {});
  }

  void _start() => startTimer(
    widget.timer,
    length: widget.length,
    title: '${widget.stepTitle} — done',
    body: widget.recipeTitle,
  );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final label = weighted(theme.textTheme.bodyMedium, FontWeight.w600);
    final end = _end;
    if (end == null) {
      return OutlinedButton.icon(
        onPressed: _start,
        icon: const Icon(Icons.timer_outlined, size: 18),
        label: Text('Start ${formatDuration(widget.length.inSeconds)} timer'),
      );
    }
    final left = end.difference(DateTime.now());
    final done = left <= Duration.zero;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        DecoratedBox(
          decoration: ShapeDecoration(
            shape: const StadiumBorder(),
            color: done ? scheme.primaryContainer : scheme.primary,
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 16, 10),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  done ? Icons.check : Icons.timer_outlined,
                  size: 18,
                  color: done ? scheme.onPrimaryContainer : scheme.onPrimary,
                ),
                const SizedBox(width: 8),
                Text(
                  done ? 'Done' : formatCountdown(left),
                  style: label?.copyWith(
                    color: done ? scheme.onPrimaryContainer : scheme.onPrimary,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ),
          ),
        ),
        IconButton(
          onPressed: () => clearTimer(widget.timer),
          tooltip: done ? 'Clear timer' : 'Cancel timer',
          icon: const Icon(Icons.close),
        ),
      ],
    );
  }
}

/// The version's cooks, newest first — two of them, then a Show all — and the
/// button that adds one. At the foot of the page, where you are when you have
/// just finished making it.
class _CookLog extends StatefulWidget {
  final List<CookEntry> entries;
  final Makes? makes;
  final String source;
  final VoidCallback onAdd;
  final ValueChanged<CookEntry> onEdit;

  const _CookLog({
    required this.entries,
    required this.makes,
    required this.source,
    required this.onAdd,
    required this.onEdit,
  });

  @override
  State<_CookLog> createState() => _CookLogState();
}

class _CookLogState extends State<_CookLog> {
  static const _collapsed = 2;

  bool _showAll = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final entries = widget.entries;
    return ColoredBox(
      color: glassFill(context),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 24, 16, 32),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  Expanded(
                    child: Text(
                      'Cook log',
                      style: theme.textTheme.headlineSmall,
                    ),
                  ),
                  if (entries.isNotEmpty)
                    Text(
                      entries.length == 1
                          ? 'Made once'
                          : 'Made ${entries.length} times',
                      style: theme.textTheme.bodyMedium?.copyWith(color: muted),
                    ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                entries.isEmpty
                    ? 'Each time you make it, log how it went. The stars up '
                          'top are the latest you gave.'
                    : 'Your rating is the latest one you gave. Tap an entry '
                          'to change it.',
                style: theme.textTheme.bodySmall?.copyWith(color: muted),
              ),
              const SizedBox(height: 12),
              for (final entry
                  in _showAll ? entries : entries.take(_collapsed)) ...[
                CookEntryLine(
                  entry: entry,
                  makes: widget.makes,
                  onTap: () => widget.onEdit(entry),
                ),
                const SizedBox(height: 8),
              ],
              if (entries.length > _collapsed)
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton(
                    onPressed: () => setState(() => _showAll = !_showAll),
                    child: Text(
                      _showAll ? 'Show less' : 'Show all (${entries.length})',
                    ),
                  ),
                ),
              const SizedBox(height: 8),
              FilledButton.icon(
                onPressed: widget.onAdd,
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(54),
                ),
                icon: const Icon(Icons.restaurant),
                label: const Text('I made it'),
              ),
              const SizedBox(height: 20),
              Text(
                'Source: ${widget.source}',
                style: theme.textTheme.bodySmall?.copyWith(color: muted),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// What [_EntryDialog] pops with: the entry to save, or to delete.
typedef _EntryResult = ({CookEntry entry, bool delete});

/// One cook, new or being edited. A dialog rather than a bottom sheet: the
/// photo picker is the app's one sheet, and this is four small fields.
class _EntryDialog extends StatefulWidget {
  final CookEntry entry;
  final bool isNew;

  /// What the stepper shows for an entry migrated without servings. Left
  /// untouched, the entry stays without them rather than claiming a number.
  final int fallbackServings;

  /// The recipe's pieces, when the count is loaves rather than servings.
  final Makes? makes;
  final Color accent;

  const _EntryDialog({
    required this.entry,
    required this.isNew,
    required this.fallbackServings,
    required this.makes,
    required this.accent,
  });

  @override
  State<_EntryDialog> createState() => _EntryDialogState();
}

class _EntryDialogState extends State<_EntryDialog> {
  late DateTime _date = widget.entry.date;
  late int? _servings = widget.entry.servings;
  late int _stars = widget.entry.stars;
  late final _note = TextEditingController(text: widget.entry.note);

  /// What each count of stars means, so the row reads as a verdict rather
  /// than a score. Index 0 is no stars at all, which is allowed.
  static const _verdicts = [
    'Stars are optional',
    'Didn’t work',
    'Needs work',
    'Fine',
    'Really good',
    'A keeper',
  ];

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  /// A cook logged the morning after is still last night's. The time of day
  /// is kept so two cooks on one day stay in order.
  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: DateTime(2000),
      lastDate: DateTime.now(),
    );
    if (picked == null) return;
    setState(() {
      _date = DateTime(
        picked.year,
        picked.month,
        picked.day,
        _date.hour,
        _date.minute,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final label = theme.textTheme.bodySmall?.copyWith(color: muted);
    final note = _note.text.trim();
    // Nothing to keep: an empty entry isn't saved, the same rule a blank
    // rating had. Clearing an existing one is what Delete is for.
    final canSave = _stars > 0 || note.isNotEmpty;
    return AlertDialog(
      // The default 40px a side leaves a 360dp phone too narrow for five
      // stars and the stepper; 16 is the app's usual gutter.
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      title: Text(widget.isNew ? 'How did it go?' : 'Edit cook'),
      content: SizedBox(
        width: double.maxFinite,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // An equal share each rather than 48px each, so the row can't
              // be wider than the dialog however narrow the phone.
              Row(
                children: [
                  for (var star = 1; star <= 5; star++)
                    Expanded(
                      child: IconButton(
                        // Tapping the current rating clears it — no extra
                        // button.
                        onPressed: () =>
                            setState(() => _stars = _stars == star ? 0 : star),
                        tooltip: star == 1 ? '1 star' : '$star stars',
                        iconSize: 34,
                        icon: Icon(
                          star <= _stars ? Icons.star : Icons.star_border,
                          color: star <= _stars ? widget.accent : muted,
                        ),
                      ),
                    ),
                ],
              ),
              Text(
                _verdicts[_stars],
                textAlign: TextAlign.center,
                style: serif(
                  20,
                  height: 1.3,
                  italic: true,
                ).copyWith(color: _stars > 0 ? widget.accent : muted),
              ),
              const SizedBox(height: 16),
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('When', style: label),
                        const SizedBox(height: 4),
                        TextButton.icon(
                          style: TextButton.styleFrom(
                            padding: EdgeInsets.zero,
                            alignment: Alignment.centerLeft,
                          ),
                          onPressed: _pickDate,
                          icon: const Icon(Icons.calendar_today, size: 18),
                          label: Text(formatDay(_date)),
                        ),
                      ],
                    ),
                  ),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(switch (widget.makes) {
                        final makes? => 'Made (${makes.other})',
                        null => 'Served',
                      }, style: label),
                      _Stepper(
                        value: _servings ?? widget.fallbackServings,
                        onChanged: (value) => setState(() => _servings = value),
                      ),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _note,
                minLines: 2,
                maxLines: 4,
                decoration: const InputDecoration(
                  hintText: 'Note for next time — what would you change?',
                ),
                onChanged: (_) => setState(() {}),
              ),
            ],
          ),
        ),
      ),
      actions: [
        if (!widget.isNew)
          TextButton(
            onPressed: () =>
                Navigator.pop(context, (entry: widget.entry, delete: true)),
            child: const Text('Delete'),
          ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: canSave
              ? () => Navigator.pop(context, (
                  entry: (
                    id: widget.entry.id,
                    date: _date,
                    servings: _servings,
                    stars: _stars,
                    note: note,
                  ),
                  delete: false,
                ))
              : null,
          child: const Text('Save'),
        ),
      ],
    );
  }
}

/// What [_PhotoSheet] returns for "use my own photo", rather than a url. It
/// cannot collide with a real one: nothing names a file `pick`.
const _ownPhoto = 'mise://pick';

/// The photo picker, and the app's one bottom sheet.
///
/// A dialog is the modal everywhere else here, and this is deliberately not
/// one: an `AlertDialog` is a letterbox, and this is nine photographs on a
/// phone. It takes an already-resolved list rather than a Future for the reason
/// spelled out on [_RecipeDetailScreenState._pickPhoto] — a spinner in a modal
/// is an animation `pumpAndSettle` waits on forever.
class _PhotoSheet extends StatelessWidget {
  final List<StockPhoto> photos;
  final RecipeStore store;

  const _PhotoSheet({required this.photos, required this.store});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 32,
                height: 4,
                margin: const EdgeInsets.symmetric(vertical: 14),
                decoration: BoxDecoration(
                  color: theme.colorScheme.onSurfaceVariant.withValues(
                    alpha: 0.4,
                  ),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            Text('Choose a photo', style: theme.textTheme.headlineSmall),
            const SizedBox(height: 12),
            if (photos.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 24),
                child: Text(
                  'No photos found. Edit the recipe and describe what it '
                  'looks like in two or three words.',
                  style: theme.textTheme.bodyMedium,
                ),
              )
            else ...[
              ConstrainedBox(
                // Half the screen, so the sheet stays a sheet: the grid
                // scrolls inside it rather than growing into a full page.
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.sizeOf(context).height * 0.5,
                ),
                child: GridView.count(
                  crossAxisCount: 3,
                  shrinkWrap: true,
                  mainAxisSpacing: 6,
                  crossAxisSpacing: 6,
                  children: [
                    for (final photo in photos)
                      InkWell(
                        onTap: () => Navigator.pop(context, photo),
                        borderRadius: BorderRadius.circular(12),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(12),
                          child: Stack(
                            fit: StackFit.expand,
                            children: [
                              Image(
                                // Through the chokepoint, so a tile and the
                                // hero can never disagree about what a url
                                // paints as.
                                image: imageFor(photo.url, store)!,
                                fit: BoxFit.cover,
                                // No loadingBuilder — see the class docs.
                                errorBuilder: (_, _, _) =>
                                    ColoredBox(color: glassFill(context)),
                              ),
                              // Unsplash asks for the photographer wherever
                              // a photo is shown, the grid included. Text,
                              // not a link: a tap on a tile picks it, and the
                              // hero carries the link once it is picked.
                              const DecoratedBox(
                                decoration: BoxDecoration(gradient: heroScrim),
                              ),
                              Positioned(
                                left: 8,
                                right: 8,
                                bottom: 6,
                                child: Text(
                                  photo.credit.name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.labelSmall?.copyWith(
                                    color: Colors.white,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Photos from Unsplash',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
            const SizedBox(height: 14),
            // The one photo that cannot 404, and the only one that is actually
            // of this dish rather than of something that looks like it.
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(
                minimumSize: const Size.fromHeight(52),
                side: BorderSide(color: glassRim(context)),
              ),
              onPressed: () => Navigator.pop(context, _ownPhoto),
              icon: const Icon(Icons.photo_camera_outlined),
              label: const Text('Use my own photo'),
            ),
          ],
        ),
      ),
    );
  }
}
