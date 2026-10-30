import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../recipe_image.dart';
import '../recipe_models.dart';
import '../recipe_parser.dart';
import '../recipe_sample.dart';
import '../recipe_scaling.dart' show baseCount, countLabel;
import '../recipe_server.dart' show serverRecipesOn;
import '../recipe_store.dart';
import '../recipe_sync.dart';
import 'create_recipe_screen.dart';
import 'glass.dart';
import 'import_recipe_screen.dart';
import 'onboarding_screen.dart';
import 'recipe_detail_screen.dart';
import 'settings_screen.dart';

/// The library, and the cook log it is sorted against.
typedef _Library = ({
  List<SavedRecipe> recipes,
  Map<String, List<CookEntry>> log,
});

class RecipeListScreen extends StatefulWidget {
  final RecipeStore store;
  final RecipeParser parser;

  /// Where the tour stood when the app opened: `new` opens it over the list,
  /// `skipped` owes its sign-in and Pro pages. [RecipeStore.onboarding] holds
  /// it; `main` reads it, so the list screen does no I/O of its own for it.
  final String onboarding;

  const RecipeListScreen({
    super.key,
    required this.store,
    required this.parser,
    this.onboarding = 'done',
  });

  @override
  State<RecipeListScreen> createState() => _RecipeListScreenState();
}

class _RecipeListScreenState extends State<RecipeListScreen> {
  late Future<_Library> _library = _load();

  /// What the search field holds, lower-cased. Empty shows the whole library.
  String _query = '';

  late bool _owed = widget.onboarding == 'skipped';

  /// The tour's recipe, which drops into its tile the first time it shows.
  String? _dropped;

  // Another phone's recipes, landed by sync.
  @override
  void initState() {
    super.initState();
    pulled.addListener(_reload);
    if (widget.onboarding == 'new') {
      WidgetsBinding.instance.addPostFrameCallback((_) => _tour());
    }
  }

  /// The recipe the tour ended on, landing in the list — after the paywall,
  /// which is what the tour's push waits for when it opens one.
  Future<void> _tour() async {
    final seen = await Navigator.push<Object?>(
      context,
      MaterialPageRoute(
        builder: (_) =>
            OnboardingScreen(store: widget.store, parser: widget.parser),
      ),
    );
    _owed = seen == null;
    if (seen is! Recipe) return;
    final id = await keepRecipe(widget.store, seen);
    if (!mounted) return;
    _dropped = id;
    _reload();
  }

  @override
  void dispose() {
    pulled.removeListener(_reload);
    super.dispose();
  }

  Future<_Library> _load() async => (
    recipes: await widget.store.loadAll(),
    log: await widget.store.allEntries(),
  );

  // Block body, not an arrow: an arrow returns the assigned Future, and
  // setState asserts on a callback that returns one.
  void _reload() {
    setState(() {
      _library = _load();
    });
  }

  Future<void> _open(SavedRecipe saved) async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => RecipeDetailScreen(
          id: saved.$1,
          recipe: saved.$2,
          store: widget.store,
          parser: widget.parser,
        ),
      ),
    );
    // An edit there saves a new version under a new id, and a cook logged
    // there can change which recipe was last made.
    if (!mounted) return;
    _reload();
    if (_owed) {
      _owed = false;
      await showOwedOnboarding(context, widget.store);
    }
  }

  /// Import or Create, which both pop with the recipe they saved.
  Future<void> _openNew(Widget screen) async {
    final imported = await Navigator.push<SavedRecipe>(
      context,
      MaterialPageRoute(builder: (_) => screen),
    );
    if (imported == null || !mounted) return;
    _reload();
    await _open(imported);
  }

  Future<void> _delete(SavedRecipe saved) async {
    await widget.store.delete(saved.$1);
    _reload();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Deleted ${saved.$2.title}'),
        action: SnackBarAction(
          label: 'Undo',
          onPressed: () async {
            await widget.store.save(saved.$2);
            _reload();
          },
        ),
      ),
    );
  }

  bool _matches(SavedRecipe saved) {
    if (_query.isEmpty) return true;
    final recipe = saved.$2;
    return [
      recipe.title,
      ...recipe.tags,
      for (final ingredient in recipe.ingredients) ingredient.name,
    ].any((text) => text.toLowerCase().contains(_query));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // No app bar to set the status bar's icons, so say it here.
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: theme.brightness == Brightness.dark
          ? SystemUiOverlayStyle.light
          : SystemUiOverlayStyle.dark,
      child: Scaffold(
        floatingActionButtonLocation: FloatingActionButtonLocation.centerFloat,
        // Tinted glass, the way iOS draws a primary action floating over
        // content: the grid scrolls under it and shows through the herb.
        // Tinted glass, the way iOS draws a primary action floating over
        // content: the grid scrolls under it and shows through the herb.
        // Create only where the server can write, which tests never are.
        floatingActionButton: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _NewButton(
              icon: Icons.add,
              label: 'Import',
              onPressed: () => _openNew(
                ImportRecipeScreen(store: widget.store, parser: widget.parser),
              ),
            ),
            if (serverRecipesOn) ...[
              const SizedBox(width: 12),
              _NewButton(
                icon: Icons.auto_awesome_outlined,
                label: 'Create',
                onPressed: () => _openNew(
                  CreateRecipeScreen(
                    store: widget.store,
                    parser: widget.parser,
                  ),
                ),
              ),
            ],
          ],
        ),
        body: FutureBuilder<_Library>(
          future: _library,
          builder: (context, snapshot) {
            // Reading a directory of small JSON files is a frame or two; a
            // spinner would only flash. It would also never stop animating,
            // which hangs pumpAndSettle in widget tests.
            if (!snapshot.hasData) return const SizedBox.shrink();
            final library = snapshot.data!;
            if (library.recipes.isEmpty) {
              return SafeArea(
                bottom: false,
                child: Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                      child: _header(context),
                    ),
                    const Expanded(child: _EmptyState()),
                  ],
                ),
              );
            }
            // Sync already runs on launch, resume and every save; this is for
            // the cook standing at a second phone who doesn't want to wait.
            return RefreshIndicator(
              onRefresh: syncNow,
              child: _body(context, library),
            );
          },
        ),
      ),
    );
  }

  // Settings is the way in to sign-in and sync, so it shows on an empty
  // library too — a second phone starts with nothing to list.
  Widget _header(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Expanded(child: Text('Recipes', style: theme.textTheme.headlineLarge)),
        IconButton.filledTonal(
          icon: const Icon(Icons.tune),
          tooltip: 'Settings',
          style: IconButton.styleFrom(
            backgroundColor: glassFill(context),
            fixedSize: const Size(48, 48),
          ),
          onPressed: () => Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => SettingsScreen(store: widget.store),
            ),
          ),
        ),
      ],
    );
  }

  Widget _body(BuildContext context, _Library library) {
    final theme = Theme.of(context);
    final searching = _query.isNotEmpty;
    // The recipe whose current version was cooked most recently. Not shown
    // while searching: a search is asking for something else.
    SavedRecipe? lastMade;
    DateTime? lastDate;
    if (!searching) {
      for (final saved in library.recipes) {
        final newest = library.log[saved.$1]?.firstOrNull?.date;
        if (newest != null && (lastDate == null || newest.isAfter(lastDate))) {
          lastMade = saved;
          lastDate = newest;
        }
      }
    }
    final shown = [
      for (final saved in library.recipes)
        if (saved != lastMade && _matches(saved)) saved,
    ];
    final heading = searching
        ? '${shown.length} found'
        : lastMade == null
        ? 'All recipes · ${shown.length}'
        : 'Everything else · ${shown.length}';
    final width = MediaQuery.sizeOf(context).width;
    // Two across on a phone, more as a tablet gives room, never a tile under
    // ~170dp — the size a title still wraps to two lines in.
    final columns = ((width - 32) / 220).floor().clamp(2, 5);

    Widget tile(SavedRecipe saved) {
      final tile = _Tile(
        saved: saved,
        stars: headlineStars(library.log[saved.$1] ?? const []),
        store: widget.store,
        onTap: () => _open(saved),
        onDelete: () => _delete(saved),
      );
      return saved.$1 == _dropped ? _DropIn(child: tile) : tile;
    }

    return CustomScrollView(
      // A short library still has to pull.
      physics: const AlwaysScrollableScrollPhysics(),
      slivers: [
        SliverSafeArea(
          bottom: false,
          sliver: SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            sliver: SliverToBoxAdapter(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _header(context),
                  const SizedBox(height: 14),
                  TextField(
                    onChanged: (value) =>
                        setState(() => _query = value.trim().toLowerCase()),
                    textInputAction: TextInputAction.search,
                    decoration: InputDecoration(
                      hintText: 'Search by name, tag or ingredient',
                      prefixIcon: const Icon(Icons.search),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(24),
                        borderSide: BorderSide.none,
                      ),
                    ),
                  ),
                  if (lastMade case final lastMade?) ...[
                    const SizedBox(height: 22),
                    SectionLabel('Last made'),
                    const SizedBox(height: 10),
                    _Featured(
                      saved: lastMade,
                      stars: headlineStars(library.log[lastMade.$1]!),
                      cooks: library.log[lastMade.$1]!.length,
                      store: widget.store,
                      onTap: () => _open(lastMade),
                    ),
                  ],
                  const SizedBox(height: 24),
                  SectionLabel(heading),
                  const SizedBox(height: 10),
                  if (shown.isEmpty && searching)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 24),
                      child: Text(
                        'Nothing matches “$_query”.',
                        style: theme.textTheme.bodyLarge?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
        SliverPadding(
          // Clears the import button floating over the last row.
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 104),
          // Rows of tiles rather than a SliverGrid: a grid cell has a fixed
          // height, and a tile is a square photo plus a title that may take one
          // line or two, at whatever text size the phone is set to.
          sliver: SliverList.builder(
            itemCount: (shown.length / columns).ceil(),
            itemBuilder: (context, row) => Padding(
              padding: const EdgeInsets.only(bottom: 20),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (var column = 0; column < columns; column++) ...[
                    if (column > 0) const SizedBox(width: 14),
                    Expanded(
                      child: row * columns + column < shown.length
                          ? tile(shown[row * columns + column])
                          : const SizedBox.shrink(),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// "bread · 4 servings · ★ 4" — what kind of thing, how big, and how it went.
///
/// The star is an icon, not a character: Geist has no ★ glyph.
InlineSpan _meta(BuildContext context, List<String> parts, int stars) {
  final color = Theme.of(context).colorScheme.primary;
  return TextSpan(
    children: [
      TextSpan(text: parts.join(' · ')),
      if (stars > 0) ...[
        TextSpan(text: parts.isEmpty ? '' : ' · '),
        WidgetSpan(
          alignment: PlaceholderAlignment.middle,
          child: Icon(Icons.star, size: 14, color: color),
        ),
        TextSpan(text: ' $stars'),
      ],
    ],
  );
}

String _servings(Recipe recipe) => countLabel(recipe, baseCount(recipe));

/// One recipe in the grid: its photo, its name, a line about it.
class _Tile extends StatelessWidget {
  final SavedRecipe saved;
  final int stars;
  final RecipeStore store;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  const _Tile({
    required this.saved,
    required this.stars,
    required this.store,
    required this.onTap,
    required this.onDelete,
  });

  /// Long-press rather than swipe: a swipe across a row is too easy to make
  /// by accident with one floury thumb. The menu is anchored on the row.
  Future<void> _showMenu(BuildContext context) async {
    final row = context.findRenderObject()! as RenderBox;
    final overlay =
        Overlay.of(context).context.findRenderObject()! as RenderBox;
    final rect = row.localToGlobal(Offset.zero, ancestor: overlay) & row.size;
    final choice = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(rect, Offset.zero & overlay.size),
      items: const [
        PopupMenuItem(
          value: 'delete',
          child: ListTile(
            leading: Icon(Icons.delete_outline),
            title: Text('Delete'),
          ),
        ),
      ],
    );
    if (choice == 'delete') onDelete();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final recipe = saved.$2;
    return InkWell(
      onTap: onTap,
      onLongPress: () => _showMenu(context),
      borderRadius: BorderRadius.circular(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AspectRatio(
            aspectRatio: 1,
            child: _Cover(recipe: recipe, store: store, radius: 16),
          ),
          const SizedBox(height: 8),
          Text(recipe.title, style: serif(21, height: 1.08)),
          const SizedBox(height: 4),
          Text.rich(
            _meta(context, [
              if (recipe.tags.isNotEmpty) recipe.tags.first,
              _servings(recipe),
            ], stars),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

/// The recipe cooked most recently, given the width of the page.
class _Featured extends StatelessWidget {
  final SavedRecipe saved;
  final int stars;
  final int cooks;
  final RecipeStore store;
  final VoidCallback onTap;

  const _Featured({
    required this.saved,
    required this.stars,
    required this.cooks,
    required this.store,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final recipe = saved.$2;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ConstrainedBox(
            // A tablet's width would otherwise make this a wall of photo.
            constraints: const BoxConstraints(maxHeight: 320),
            child: AspectRatio(
              aspectRatio: 16 / 10,
              child: _Cover(recipe: recipe, store: store, radius: 20),
            ),
          ),
          const SizedBox(height: 10),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: Text(recipe.title, style: serif(28, height: 1.05)),
              ),
              const SizedBox(width: 12),
              Text.rich(
                _meta(context, ['made $cooks×'], stars),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// The recipe's photo, or — while one is being found, and for a recipe that
/// never gets one — generated art: its tag hue, lit from the top left, under
/// the initial of its title. Fills whatever box it is given.
///
/// Runs the full [ImageChain], Wikipedia fallback included. The import prompt
/// no longer asks the model to pad `image_urls` with guesses, so most tiles
/// spend no attempt on urls of their own, and [wikipediaImage] is memoised per
/// title — a tile shares its lookup with the detail screen and with every
/// other recipe for the same dish.
// ponytail: still one API call per distinct title on first scroll. Resolve only
// what is already in the memo if a large library ever makes that felt.
class _Cover extends StatefulWidget {
  final Recipe recipe;
  final RecipeStore store;
  final double radius;

  const _Cover({
    required this.recipe,
    required this.store,
    required this.radius,
  });

  @override
  State<_Cover> createState() => _CoverState();
}

class _CoverState extends State<_Cover> {
  ImageChain? _chain;

  /// Guarded because `didChangeDependencies` runs again on a theme or metrics
  /// change, and restarting the chain there would re-spend every attempt.
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    _start();
  }

  /// Tiles are keyed by recipe id, so this mostly guards a reload that swaps a
  /// recipe's content under the id it already had.
  @override
  void didUpdateWidget(_Cover oldWidget) {
    super.didUpdateWidget(oldWidget);
    final was = oldWidget.recipe;
    final now = widget.recipe;
    if (listEquals(was.imageUrls, now.imageUrls) &&
        was.title == now.title &&
        was.imageQuery == now.imageQuery) {
      return;
    }
    _start();
  }

  void _start() {
    _chain?.dispose();
    _chain = ImageChain(
      widget.recipe.imageUrls,
      widget.store,
      () {
        if (mounted) setState(() {});
      },
      title: widget.recipe.title,
      query: widget.recipe.imageQuery,
    );
    _chain!.resolve(createLocalImageConfiguration(context));
  }

  @override
  void dispose() {
    _chain?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final recipe = widget.recipe;
    final accent = tagAccent(context, recipe.tags);
    final image = imageFor(_chain?.winner, widget.store);
    final initial = Center(
      child: Text(
        recipe.title.characters.first.toUpperCase(),
        style: serif(44).copyWith(color: onAccent(accent)),
      ),
    );
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(widget.radius),
        gradient: coverGradient(accent),
      ),
      // The generated art stays underneath rather than being an alternative to
      // the photo, so it is what shows through while the chain is still looking
      // and what is left when it comes back with nothing. No loadingBuilder — a
      // spinner per tile would be dozens of indefinite animations (CLAUDE.md).
      child: image == null
          ? initial
          : Stack(
              fit: StackFit.expand,
              children: [
                Image(
                  image: image,
                  fit: BoxFit.cover,
                  errorBuilder: (context, _, _) => initial,
                ),
                // Unsplash asks for the photographer wherever a photo is shown.
                // Text only: a tap opens the recipe, whose hero has the links.
                if (_photographer() case final name?) ...[
                  const DecoratedBox(
                    decoration: BoxDecoration(gradient: heroScrim),
                  ),
                  Positioned(
                    left: 10,
                    right: 10,
                    bottom: 8,
                    child: Text(
                      name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: Colors.white.withValues(alpha: 0.85),
                      ),
                    ),
                  ),
                ],
              ],
            ),
    );
  }

  /// Who took the photo on this tile: the recipe's own credit while its kept
  /// photo is the one showing, or a search result's before it has been kept.
  String? _photographer() {
    final winner = _chain?.winner;
    if (winner == null) return null;
    if (winner == widget.recipe.imageUrls.firstOrNull) {
      return widget.recipe.imageCredit?.name;
    }
    return _chain?.winnerFromSearch?.credit.name;
  }
}

/// Falls into place once, a beat after it is first built: long enough for
/// the route above it to have slid away.
class _DropIn extends StatelessWidget {
  final Widget child;
  const _DropIn({required this.child});

  @override
  Widget build(BuildContext context) => TweenAnimationBuilder<double>(
    tween: Tween(begin: 0, end: 1),
    duration: MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : const Duration(milliseconds: 1100),
    curve: const Interval(0.3, 1, curve: Curves.easeOutBack),
    builder: (context, t, child) => Opacity(
      opacity: t.clamp(0.0, 1.0),
      child: Transform.translate(
        offset: Offset(0, -80 * (1 - t)),
        child: Transform.scale(scale: 0.9 + 0.1 * t, child: child),
      ),
    ),
    child: child,
  );
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'No recipes yet',
                textAlign: TextAlign.center,
                style: theme.textTheme.headlineMedium,
              ),
              const SizedBox(height: 12),
              Text(
                'Tap Import to paste one from an LLM. “Copy prompt” there '
                'gets it in the right shape.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyLarge?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One of the two floating pills, Import and Create.
class _NewButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onPressed;

  const _NewButton({
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) => frost(
    context: context,
    shape: const StadiumBorder(),
    tint: Theme.of(context).colorScheme.primary.withValues(alpha: 0.86),
    lift: true,
    child: FloatingActionButton.extended(
      heroTag: label,
      onPressed: onPressed,
      backgroundColor: Colors.transparent,
      elevation: 0,
      focusElevation: 0,
      hoverElevation: 0,
      highlightElevation: 0,
      icon: Icon(icon),
      label: Text(label),
    ),
  );
}
