import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';

import '../recipe_image.dart';
import '../recipe_parser.dart';
import '../recipe_store.dart';
import 'glass.dart';
import 'import_recipe_screen.dart';
import 'recipe_detail_screen.dart';
import 'settings_screen.dart';

class RecipeListScreen extends StatefulWidget {
  final RecipeStore store;
  final RecipeParser parser;

  const RecipeListScreen({
    super.key,
    required this.store,
    required this.parser,
  });

  @override
  State<RecipeListScreen> createState() => _RecipeListScreenState();
}

class _RecipeListScreenState extends State<RecipeListScreen> {
  late Future<List<SavedRecipe>> _recipes = widget.store.loadAll();

  // Block body, not an arrow: an arrow returns the assigned Future, and
  // setState asserts on a callback that returns one.
  void _reload() {
    setState(() {
      _recipes = widget.store.loadAll();
    });
  }

  Future<void> _openImport() async {
    final imported = await Navigator.push<SavedRecipe>(
      context,
      MaterialPageRoute(
        builder: (_) =>
            ImportRecipeScreen(store: widget.store, parser: widget.parser),
      ),
    );
    if (imported == null || !mounted) return;
    _reload();
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => RecipeDetailScreen(
          id: imported.$1,
          recipe: imported.$2,
          store: widget.store,
          parser: widget.parser,
        ),
      ),
    );
    // Editing from the detail screen saves a new version under a new id, so
    // the row that opened it is stale by the time we come back.
    if (mounted) _reload();
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

  @override
  Widget build(BuildContext context) {
    // Read here rather than down in the builders: this context sits above the
    // Scaffold, which is where the inset is the app bar's height once. See
    // glassAppBarInset.
    final appBarInset = glassAppBarInset(context);
    return GlassScaffold(
      appBar: glassAppBar(
        context,
        title: const Text('Mise'),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            tooltip: 'Settings',
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => SettingsScreen(store: widget.store),
              ),
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _openImport,
        icon: const Icon(Icons.add),
        label: const Text('Import'),
      ),
      body: FutureBuilder<List<SavedRecipe>>(
        future: _recipes,
        builder: (context, snapshot) {
          // Reading a directory of small JSON files is a frame or two; a
          // spinner would only flash. It would also never stop animating,
          // which hangs pumpAndSettle in widget tests.
          if (!snapshot.hasData) return const SizedBox.shrink();
          final recipes = snapshot.data!;
          if (recipes.isEmpty) return _EmptyState(appBarInset: appBarInset);
          final colors = Theme.of(context).colorScheme;
          return ListView.builder(
            // Rows run edge to edge, so the only padding is vertical: clear the
            // blurred app bar the body scrolls under, and the FAB at the bottom.
            padding: EdgeInsets.only(top: appBarInset, bottom: 88),
            itemCount: recipes.length,
            itemBuilder: (context, index) {
              final saved = recipes[index];
              return Dismissible(
                key: ValueKey(saved.$1),
                direction: DismissDirection.endToStart,
                background: Container(
                  alignment: Alignment.centerRight,
                  padding: const EdgeInsets.only(right: 24),
                  color: colors.error.withValues(alpha: 0.22),
                  child: Icon(Icons.delete_outline, color: colors.error),
                ),
                onDismissed: (_) => _delete(saved),
                child: _RecipeRow(
                  saved: saved,
                  store: widget.store,
                  parser: widget.parser,
                  onReturn: _reload,
                  // The sheet's own bottom edge closes the last row.
                  ruled: index < recipes.length - 1,
                ),
              );
            },
          );
        },
      ),
    );
  }
}

/// Art size, and the inset the divider takes so it starts at the title rather
/// than the screen edge.
const _coverSize = 64.0;
const _dividerIndent = 16.0 + _coverSize + 12.0;

/// A track row: generated cover, title, the shape of the recipe, its tags.
///
/// Full bleed, and the fill is the panel fill rather than a margin'd
/// [GlassPanel], so a run of rows reads as one sheet of glass with hairlines
/// ruled across it.
class _RecipeRow extends StatelessWidget {
  final SavedRecipe saved;
  final RecipeStore store;
  final RecipeParser parser;
  final bool ruled;

  /// Called on the way back from the detail screen: an edit there saves a new
  /// version under a new id, which this row does not know about.
  final VoidCallback onReturn;

  const _RecipeRow({
    required this.saved,
    required this.store,
    required this.parser,
    required this.ruled,
    required this.onReturn,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final recipe = saved.$2;
    // A recipe keeps its colour: the same hue the detail screen's backdrop
    // takes, here carrying the cover and the tag that named it.
    final accent = tagAccent(context, recipe.tags);
    return Material(
      color: glassFill(context),
      child: InkWell(
        onTap: () async {
          await Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => RecipeDetailScreen(
                id: saved.$1,
                recipe: recipe,
                store: store,
                parser: parser,
              ),
            ),
          );
          onReturn();
        },
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: Row(
                children: [
                  _Cover(
                    letter: recipe.title[0].toUpperCase(),
                    accent: accent,
                    urls: recipe.imageUrls,
                    title: recipe.title,
                    store: store,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          recipe.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleMedium,
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '${recipe.baseServings} '
                          '${recipe.baseServings == 1 ? 'serving' : 'servings'}'
                          ' · ${recipe.steps.length} steps',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall,
                        ),
                        if (recipe.tags.isNotEmpty) ...[
                          const SizedBox(height: 6),
                          _TagStrip(tags: recipe.tags),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
            if (ruled)
              Divider(
                height: 1,
                thickness: 1,
                // Starts at the title rather than the screen edge, so the run
                // of covers down the left reads as its own column.
                indent: _dividerIndent,
                color: glassRim(context),
              ),
          ],
        ),
      ),
    );
  }
}

/// The recipe's photo, or — while one is being found, and for a recipe that
/// never gets one — generated art: its tag hue, lit from the top left, under
/// the initial of its title.
///
/// Runs the full [ImageChain], Wikipedia fallback included, which the list used
/// to skip on the grounds that several network attempts per row is a real cost.
/// It is a smaller cost than it was: the import prompt no longer asks the model
/// to pad `image_urls` with guesses, so most rows spend no attempt on urls of
/// their own, and [wikipediaImage] is memoised per title — a row shares its
/// lookup with the detail screen and with every other recipe for the same dish.
// ponytail: still one API call per distinct title on first scroll. Resolve only
// what is already in the memo if a large library ever makes that felt.
class _Cover extends StatefulWidget {
  final String letter;
  final Color accent;
  final List<String> urls;

  /// The dish, for the fallback — see [ImageChain.title].
  final String title;
  final RecipeStore store;

  const _Cover({
    required this.letter,
    required this.accent,
    required this.urls,
    required this.title,
    required this.store,
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

  /// Rows are keyed by recipe id, so this mostly guards a reload that swaps a
  /// recipe's content under the id it already had.
  @override
  void didUpdateWidget(_Cover oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (listEquals(oldWidget.urls, widget.urls) &&
        oldWidget.title == widget.title) {
      return;
    }
    _start();
  }

  void _start() {
    _chain?.dispose();
    _chain = ImageChain(widget.urls, widget.store, () {
      if (mounted) setState(() {});
    }, title: widget.title);
    _chain!.resolve(createLocalImageConfiguration(context));
  }

  @override
  void dispose() {
    _chain?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final accent = widget.accent;
    final image = imageFor(_chain?.winner, widget.store);
    final initial = Text(
      widget.letter,
      style: Theme.of(
        context,
      ).textTheme.titleMedium?.copyWith(fontSize: 22, color: onAccent(accent)),
    );
    return Container(
      width: _coverSize,
      height: _coverSize,
      alignment: Alignment.center,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(pillRadius),
        gradient: coverGradient(accent),
      ),
      // The generated art stays underneath rather than being an alternative to
      // the photo, so it is what shows through while the chain is still looking
      // and what is left when it comes back with nothing. No loadingBuilder — a
      // spinner per row would be dozens of indefinite animations (CLAUDE.md).
      child: image == null
          ? initial
          : Image(
              image: image,
              width: _coverSize,
              height: _coverSize,
              fit: BoxFit.cover,
              errorBuilder: (context, _, _) => initial,
            ),
    );
  }
}

/// One line of tags, scrolled rather than wrapped, so a heavily tagged recipe
/// can't grow its row taller than the rest. Whichever edge still has tags out
/// of view fades out, so a cut-off row reads as scrollable rather than clipped.
///
/// SingleChildScrollView and not a horizontal ListView: it keeps every chip
/// built, so off-screen tags stay findable in widget tests.
class _TagStrip extends StatefulWidget {
  final List<String> tags;

  const _TagStrip({required this.tags});

  @override
  State<_TagStrip> createState() => _TagStripState();
}

class _TagStripState extends State<_TagStrip> {
  bool _fadeStart = false;
  bool _fadeEnd = false;

  /// Metrics arrive from two places: ScrollMetricsNotification on first layout
  /// and on resize, ScrollNotification while dragging. Neither alone covers
  /// both, and the row must already be faded before anyone touches it.
  bool _sync(ScrollMetrics metrics) {
    final start = metrics.extentBefore > 1;
    final end = metrics.extentAfter > 1;
    if (start == _fadeStart && end == _fadeEnd) return false;
    // The first-layout notification lands mid-frame, so defer the rebuild.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      setState(() {
        _fadeStart = start;
        _fadeEnd = end;
      });
    });
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final scroller = SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          for (final tag in widget.tags)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: Chip(
                label: Text(tag),
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
              ),
            ),
        ],
      ),
    );

    return NotificationListener<ScrollMetricsNotification>(
      onNotification: (n) => _sync(n.metrics),
      child: NotificationListener<ScrollNotification>(
        onNotification: (n) => _sync(n.metrics),
        // ShaderMask costs a save layer, so skip it entirely on the common
        // card whose tags all fit.
        child: !_fadeStart && !_fadeEnd
            ? scroller
            : ShaderMask(
                blendMode: BlendMode.dstIn,
                shaderCallback: (bounds) => LinearGradient(
                  begin: Alignment.centerLeft,
                  end: Alignment.centerRight,
                  colors: [
                    _fadeStart ? Colors.transparent : Colors.white,
                    Colors.white,
                    Colors.white,
                    _fadeEnd ? Colors.transparent : Colors.white,
                  ],
                  stops: const [0, 0.08, 0.92, 1],
                ).createShader(bounds),
                child: scroller,
              ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  final double appBarInset;

  const _EmptyState({required this.appBarInset});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: EdgeInsets.fromLTRB(32, 32 + appBarInset, 32, 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.menu_book_outlined,
              size: 56,
              color: theme.colorScheme.primary,
            ),
            const SizedBox(height: 16),
            Text('No recipes yet', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(
              'Tap Import to paste a recipe from an LLM. Use "Copy prompt" '
              'there to get one in the right shape.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium,
            ),
          ],
        ),
      ),
    );
  }
}
