import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../recipe_image.dart';
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

class _RecipeDetailScreenState extends State<RecipeDetailScreen>
    with SingleTickerProviderStateMixin {
  /// The version on screen. Editing swaps these for the newly saved version
  /// in place, rather than pushing another copy of this screen.
  late String _id = widget.id;
  late Recipe _recipe = widget.recipe;

  late int _servings = widget.recipe.baseServings;

  /// Ingredients tapped into their other dimension. Deliberately not
  /// persisted — this is "my scale is dirty, show me cups", not a preference.
  final _flipped = <String>{};
  final _noteController = TextEditingController();
  int _stars = 0;

  /// The recipe's photos, tried in order until one loads. Null until the first
  /// [didChangeDependencies], which is the earliest an ImageConfiguration
  /// exists to resolve against.
  ImageChain? _photos;

  /// What [_photos] was built for, so a theme or metrics change re-entering
  /// [didChangeDependencies] doesn't restart the chain and re-open a hero that
  /// has already closed.
  List<String>? _photoUrls;

  /// Eases the hero shut when every url has failed. Finite and runs at most
  /// once per recipe, so `pumpAndSettle` still returns (see CLAUDE.md).
  late final _close = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 200),
  );

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
    if (listEquals(_photoUrls, _recipe.imageUrls)) return;
    _photos?.dispose();
    _photoUrls = _recipe.imageUrls;
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
        }
      },
      // Always, not only as a rescue for urls that failed: the import prompt
      // now tells the model to leave image_urls empty rather than invent one,
      // so a recipe with no urls at all is the common case and the one most
      // in need of a photo.
      title: _recipe.title,
    );
    _photos!.resolve(createLocalImageConfiguration(context));
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
    _photos?.dispose();
    _close.dispose();
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
        text: formatForSharing(_recipe, _servings, flipped: _flipped),
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
      // No `appBar`: the photo has to scroll *under* the bar rather than sit
      // below it, and Scaffold.appBar only takes a PreferredSizeWidget.
      //
      // ponytail: this rebuilds the whole scroll view for the 200ms the hero
      // spends closing. A sliver-typed wrapper if it ever shows up in a trace.
      body: AnimatedBuilder(
        animation: _close,
        builder: (context, _) => CustomScrollView(
          slivers: [
            _hero(context, accent),
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
              sliver: SliverList.list(
                children: [
                  // The recipe's name, and what kind of thing it is. Centred
                  // and free to wrap: a toolbar could only ever give it 56px,
                  // which is two lines and a truncation.
                  Text(
                    recipe.title,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.headlineMedium,
                  ),
                  if (recipe.tags.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    // Up here rather than at the foot of the page: tagAccent
                    // draws the whole screen's colour from the first of these,
                    // so this is where the hue gets explained.
                    Wrap(
                      alignment: WrapAlignment.center,
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final tag in recipe.tags) Chip(label: Text(tag)),
                      ],
                    ),
                  ],
                  const SizedBox(height: 28),
                  if (recipe.description.isNotEmpty) ...[
                    Text(recipe.description, style: theme.textTheme.bodyLarge),
                    const SizedBox(height: 16),
                  ],
                  _ServingsStepper(
                    servings: _servings,
                    onChanged: (value) => setState(() => _servings = value),
                  ),
                  const SizedBox(height: 24),
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
                  Text('Ingredients', style: theme.textTheme.titleLarge),
                  const SizedBox(height: 8),
                  for (final ingredient in recipe.ingredients)
                    InkWell(
                      // The whole line, not just the amount: one line is one
                      // ingredient, and a bare text run is a target too small for a
                      // hand that is also holding a bowl. InkWell rather than a bare
                      // GestureDetector so the row is reachable by keyboard and
                      // announced as a button — a detector is neither. Every row
                      // taps, including the ones that can't switch; those answer
                      // with a SnackBar rather than nothing.
                      onTap: () => _toggle(ingredient),
                      // The default focus overlay is invisible against the backdrop,
                      // and a keyboard user needs to see where they are.
                      focusColor: accent.withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(pillRadius),
                      // The band sits inside the tap target rather than being it:
                      // trimming the box the InkWell owns would cost finger-sized,
                      // and two banded rows in a row need a gap or they fuse.
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 3),
                        // Ink, not a DecoratedBox, so it paints *on* the Material
                        // and the InkWell's focus and splash still land above it.
                        child: Ink(
                          decoration: BoxDecoration(
                            // Marks an amount computed through a density, not one the
                            // reader tapped: a tap back onto the stored unit clears
                            // it, and the setting lights a whole recipe at once.
                            color:
                                isDerived(
                                  ingredient,
                                  flip: _flipped.contains(ingredient.id),
                                )
                                ? accent.withValues(alpha: 0.10)
                                : null,
                            borderRadius: BorderRadius.circular(pillRadius),
                          ),
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(8, 7, 8, 7),
                            child: Row(
                              children: [
                                Expanded(
                                  // The amount sits in the run of text, so a long name
                                  // wraps under it instead of into a narrow second
                                  // column. It stays a WidgetSpan only so it can
                                  // crossfade when the servings change; the baseline
                                  // alignment is what keeps it reading as one line.
                                  child: Text.rich(
                                    TextSpan(
                                      children: [
                                        WidgetSpan(
                                          alignment:
                                              PlaceholderAlignment.baseline,
                                          baseline: TextBaseline.alphabetic,
                                          child: Padding(
                                            padding: const EdgeInsets.only(
                                              right: 6,
                                            ),
                                            child: _Amount(
                                              label: amountLabel(
                                                ingredient,
                                                factor,
                                                flip: _flipped.contains(
                                                  ingredient.id,
                                                ),
                                              ),
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
                                if (canConvert(ingredient))
                                  Icon(
                                    Icons.swap_horiz,
                                    size: 20,
                                    color: accent.withValues(alpha: 0.75),
                                  ),
                              ],
                            ),
                          ),
                        ),
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
                      flipped: _flipped,
                      accent: accent,
                    ),
                  if (recipe.notes case final notes? when notes.isNotEmpty) ...[
                    const SizedBox(height: 24),
                    Text('Notes', style: theme.textTheme.titleLarge),
                    const SizedBox(height: 8),
                    Text(notes, style: theme.textTheme.bodyLarge),
                  ],
                  const SizedBox(height: 16),
                  Text(
                    'Source: ${recipe.source}',
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// The bar, and the photo behind it when there is one.
  ///
  /// Without any urls this is exactly the bar the rest of the app uses. With
  /// them, the photo scrolls up under a frost that fogs in as it goes — the
  /// blur in [frostPane] has spent this app's whole life smoothing a gradient,
  /// and a photograph is the first thing it has had to actually fog.
  ///
  /// When every url turns out to be dead the hero eases shut and this becomes
  /// the plain bar: a recipe whose photos don't load is a recipe with no photo,
  /// not one wearing generated art in a picture's place.
  Widget _hero(BuildContext context, Color accent) {
    final actions = [
      // Only where there is nothing to look at — a stand-in from Wikipedia
      // counts, and a recipe wearing one is not the one crying out for a
      // photo. The one image that cannot 404 is the one already on the phone,
      // and until now nothing on this screen said the editor could take it.
      if (_photos?.winner == null)
        IconButton(
          onPressed: () => _edit(pickImage: true),
          tooltip: 'Add photo',
          icon: const Icon(Icons.add_a_photo_outlined),
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
        icon: const Icon(Icons.share),
      ),
    ];

    if (_recipe.imageUrls.isEmpty && _photos?.winner == null) {
      // Nothing on screen and nothing claimed: either the lookup is still out
      // or it missed. Pixel-identical to what every other screen shows, so a
      // recipe with no photo pays nothing for a feature it isn't using — and
      // a fallback that arrives late finds the hero shut and opens it.
      return SliverAppBar(
        pinned: true,
        actions: actions,
        flexibleSpace: frostPane(context),
      );
    }

    final collapsed = MediaQuery.paddingOf(context).top + kToolbarHeight;
    // A third of the screen: enough that the photo is the thing you land on,
    // little enough that a recipe read at a counter is still one thumb-scroll
    // from its ingredients. Clamped so a phone in landscape isn't all picture
    // and a tablet gets its extra room.
    final full = (MediaQuery.sizeOf(context).height * 0.32).clamp(220.0, 340.0);
    // Rides _close down to the toolbar when the chain gives up. At the bottom
    // the SliverAppBar is already shaped exactly like the plain one, so there
    // is no second widget to cross-fade into.
    final expanded = full - (full - collapsed) * _close.value;
    final winner = _photos?.winner;

    // SliverLayoutBuilder, not a ScrollController: the fog is a function of how
    // far this sliver has scrolled, which layout already knows. The only thing
    // that animates is _close, which is finite (see CLAUDE.md).
    return SliverLayoutBuilder(
      builder: (context, constraints) {
        // Goes to zero as the hero closes, and dividing by it would put a NaN
        // straight into the frost's opacity.
        final span = expanded - collapsed;
        final open = span <= 0
            ? 0.0
            : (1 - constraints.scrollOffset / span).clamp(0.0, 1.0);
        return SliverAppBar(
          pinned: true,
          expandedHeight: expanded,
          // Icons ride from white over the photo to the page's own ink over the
          // frost. A fixed colour loses one end or the other: white vanishes
          // into the light theme's frost, and slate vanishes into a dark photo.
          foregroundColor: Color.lerp(
            Theme.of(context).colorScheme.onSurface,
            Colors.white,
            open,
          ),
          flexibleSpace: Stack(
            fit: StackFit.expand,
            children: [
              FlexibleSpaceBar(
                // No `title`. It used to sit here and get blurred away by the
                // frost stacked above — the recipe's name is set in the page
                // body now, where it can wrap instead of ellipsising.
                background: _HeroImage(
                  image: imageFor(winner, widget.store),
                  accent: accent,
                  // The url that actually loaded, not the one ranked first.
                  credit: creditFor(winner),
                ),
              ),
              frostPane(context, opacity: 1 - open),
            ],
          ),
          actions: actions,
        );
      },
    );
  }
}

/// The photo, its wash, and the line saying where it came from.
class _HeroImage extends StatelessWidget {
  /// Null once every url has failed. The hero is on its way shut by then, so
  /// there is nothing to put in the picture's place.
  final ImageProvider? image;
  final Color accent;
  final String? credit;

  const _HeroImage({
    required this.image,
    required this.accent,
    required this.credit,
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
        DecoratedBox(
          decoration: BoxDecoration(gradient: heroScrim(context, accent)),
        ),
        if (credit case final credit?)
          // The corner a photo credit belongs in. It had to clear the title
          // above it once; nothing sits over the picture now but the toolbar.
          Positioned(left: 16, right: 16, bottom: 16, child: _Credit(credit)),
      ],
    );
  }
}

/// Where the picture came from. Small, letterspaced and held back — this is
/// attribution, and it answers "is this the dish, or a stock photo?" without
/// competing with the title underneath it.
///
/// White in both themes: the scrim it sits on is deepened toward the page floor
/// either way, so this is always ink on a dark ground.
class _Credit extends StatelessWidget {
  final String text;

  const _Credit(this.text);

  @override
  Widget build(BuildContext context) {
    final ink = Colors.white.withValues(alpha: 0.78);
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
  final Set<String> flipped;
  final Color accent;

  const _StepCard({
    required this.number,
    required this.step,
    required this.recipe,
    required this.factor,
    required this.flipped,
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
              renderContent(step, recipe, factor, flipped: flipped),
              style: theme.textTheme.bodyLarge,
            ),
          ],
        ),
      ),
    );
  }
}
