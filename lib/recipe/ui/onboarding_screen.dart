import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../recipe_account.dart';
import '../recipe_models.dart';
import '../recipe_parser.dart';
import '../recipe_pro.dart';
import '../recipe_sample.dart';
import '../recipe_scaling.dart';
import '../recipe_server.dart';
import '../recipe_store.dart';
import 'glass.dart';
import 'pro_screen.dart';
import 'settings_screen.dart' show runAccountAction;
import 'writing.dart';

/// What a page of the tour is about, and so what the card above its words
/// shows: one recipe card that changes as the pages swipe by.
enum _Stage { photo, scale, log, sync, create, keep }

const _words = <_Stage, (String, String)>{
  _Stage.photo: (
    'A photo for every recipe',
    'Mise finds one that looks like the dish, and names who took it.',
  ),
  _Stage.scale: (
    'Any size, any units',
    'Change how many and every amount follows, even inside the steps.',
  ),
  _Stage.log: (
    'Cook it, then note it',
    'Stars and a note each time you make it. Every edit is kept.',
  ),
  _Stage.sync: (
    'On every phone',
    'Sign in and your recipes, photos and notes follow you.',
  ),
  _Stage.create: (
    'Now you try',
    'Say what you feel like eating and Mise writes it. Or keep the focaccia.',
  ),
  _Stage.keep: (
    'Your first recipe',
    'The focaccia is yours to keep. Import more from the list.',
  ),
};

/// The ideas under the composer, from a glass to an afternoon.
const _ideas = [
  ('Quick', 'A mango smoothie'),
  ('Weekend', 'A lemon olive-oil cake'),
  ('Project', 'A chocolate hazelnut entremet'),
];

/// The tour: a few pages over one card, then — on a first launch — a recipe
/// of the cook's own, then sign-in and the Pro paywall where this build has
/// them. Pops with the [Recipe] to keep when it ended on one, true when it was
/// seen through without, and nothing on Skip or back from the first page.
///
/// [followUp] is just the sign-in page, for a cook who skipped the tour —
/// [showOwedOnboarding] is what opens it that way.
class OnboardingScreen extends StatefulWidget {
  final RecipeStore store;

  /// Only the first launch passes one, and only then does the tour end on a
  /// recipe: Settings' replay explains and keeps nothing.
  final RecipeParser? parser;
  final bool followUp;

  /// [accountsOn] and [proOn] unless given, which only tests do: both are
  /// off under `flutter test`.
  final bool? accounts;
  final bool? pro;

  const OnboardingScreen({
    super.key,
    required this.store,
    this.parser,
    this.followUp = false,
    @visibleForTesting this.accounts,
    @visibleForTesting this.pro,
  });

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  late final bool _accounts = widget.accounts ?? accountsOn;
  late final bool _pro = widget.pro ?? proOn;
  late final _stages = [
    if (!widget.followUp) ...[_Stage.photo, _Stage.scale, _Stage.log],
    if (_accounts) _Stage.sync,
    if (widget.parser != null && !widget.followUp)
      serverRecipesOn ? _Stage.create : _Stage.keep,
  ];
  final _pages = PageController();
  final _idea = TextEditingController();
  int _page = 0;

  /// Pages reached at least once: each one's flourish plays the first time.
  late final _landed = {_stages.first};

  /// The scale page's stepper, and whether its flour has switched units.
  late int _count = baseCount(sampleRecipe);
  bool _flipped = false;

  /// The create page: the verbs while writing, then what was written or why
  /// it wasn't.
  List<String>? _writing;
  Recipe? _written;
  String? _failed;

  _Stage get _stage => _stages[_page];
  bool get _last => _page == _stages.length - 1;

  @override
  void dispose() {
    _pages.dispose();
    _idea.dispose();
    super.dispose();
  }

  Duration _motion(int ms) => MediaQuery.disableAnimationsOf(context)
      ? Duration.zero
      : Duration(milliseconds: ms);

  void _landedOn(int page) {
    setState(() {
      _page = page;
      // Doubles itself once, so the amounts are seen to follow.
      if (_landed.add(_stages[page]) && _stages[page] == _Stage.scale) {
        _count = baseCount(sampleRecipe) * 2;
      }
    });
  }

  void _turn(int by) => _pages.animateToPage(
    _page + by,
    duration: _motion(420),
    curve: Curves.easeOutCubic,
  );

  void _next() => _last ? _finish() : _turn(1);

  /// Seen through: nothing is owed any more, and Pro takes this page's place
  /// so back from the paywall lands on the list, not on the tour. The list
  /// keeps [keep], once the paywall is out of the way.
  void _finish([Recipe? keep]) {
    unawaited(widget.store.setOnboarding('done'));
    final Object result = keep ?? true;
    final navigator = Navigator.of(context);
    if (_pro && proUntil.value == null) {
      navigator.pushReplacement(
        MaterialPageRoute<void>(builder: (_) => const ProScreen()),
        result: result,
      );
    } else {
      navigator.pop(result);
    }
  }

  /// Waits on this page rather than walking on: the card is about to become
  /// the cook's own, and that is the thing to watch.
  Future<void> _write() async {
    final idea = _idea.text.trim();
    if (idea.isEmpty) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _writing = verbsFor(idea);
      _failed = null;
    });
    Recipe? written;
    String? failed;
    try {
      // main() never waits for the anonymous sign-in, and a first launch can
      // get here before it settles.
      for (var i = 0; accessToken == null && i < 20; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 500));
      }
      written = widget.parser!.parse(await askForRecipe(text: idea));
    } on RecipeValidationException {
      failed = 'It didn\'t come out right.';
    } on ServerRecipeException catch (e) {
      failed = e.message;
    }
    if (!mounted) return;
    setState(() {
      _writing = null;
      _written = written;
      _failed = failed;
    });
  }

  /// 1 on [stage]'s page, falling to 0 a page away: what the card is made of
  /// at the current scroll position, so it moves with the finger.
  double _at(_Stage stage, double page) {
    final index = _stages.indexOf(stage);
    return index == -1 ? 0 : (1 - (page - index).abs()).clamp(0.0, 1.0);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Back walks the pages; only from the first does it leave, as a skip.
    return PopScope(
      canPop: _page == 0,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _turn(-1);
      },
      child: AnnotatedRegion<SystemUiOverlayStyle>(
        // No app bar to set the status bar's icons, so say it here.
        value: theme.brightness == Brightness.dark
            ? SystemUiOverlayStyle.light
            : SystemUiOverlayStyle.dark,
        child: ValueListenableBuilder(
          valueListenable: account,
          builder: (context, current, _) {
            final signedOut = _stage == _Stage.sync && current?.email == null;
            return Scaffold(
              bottomNavigationBar: SafeArea(
                child: Padding(
                  padding: EdgeInsets.fromLTRB(
                    16,
                    8,
                    16,
                    8 + MediaQuery.viewInsetsOf(context).bottom,
                  ),
                  child: _buttons(signedOut),
                ),
              ),
              body: SafeArea(
                bottom: false,
                child: AnimatedBuilder(
                  animation: _pages,
                  builder: (context, _) {
                    final page =
                        _pages.hasClients && _pages.position.haveDimensions
                        ? _pages.page!
                        : _page.toDouble();
                    return Column(
                      children: [
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                          child: Row(
                            children: [
                              const RoundBackButton(),
                              const Spacer(),
                              if (_stages.length > 1) _dots(page),
                            ],
                          ),
                        ),
                        Expanded(child: _spread(page, current?.email)),
                      ],
                    );
                  },
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  /// Which page this is, as dots that stretch with the swipe.
  Widget _dots(double page) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      children: [
        for (final stage in _stages)
          Container(
            margin: const EdgeInsets.symmetric(horizontal: 3),
            width: 6 + 14 * _at(stage, page),
            height: 6,
            decoration: BoxDecoration(
              color: Color.lerp(
                glassRim(context),
                scheme.primary,
                _at(stage, page),
              ),
              borderRadius: BorderRadius.circular(3),
            ),
          ),
      ],
    );
  }

  /// The words swipe in a PageView; the card sits over it, above the words,
  /// and lets the swipe through except to the stepper it is showing off.
  Widget _spread(double page, String? email) {
    final typing = MediaQuery.viewInsetsOf(context).bottom > 0;
    final compact = _at(_Stage.create, page) + _at(_Stage.keep, page);
    final settled = (page - page.roundToDouble()).abs() < 0.01;
    return LayoutBuilder(
      builder: (context, box) {
        final full = math.min(360.0, box.maxHeight * 0.6);
        // The keyboard needs the room more than the card does.
        final space = typing
            ? 0.0
            : lerpDouble(full, math.min(full, 220.0), compact)!;
        return Stack(
          children: [
            PageView(
              controller: _pages,
              onPageChanged: _landedOn,
              children: [
                for (final stage in _stages) _wordsFor(stage, space, email),
              ],
            ),
            Positioned(
              top: 12,
              left: 16,
              right: 16,
              height: math.max(0, space - 12),
              child: IgnorePointer(
                ignoring: !(settled && _stage == _Stage.scale),
                child: Align(
                  alignment: Alignment.topCenter,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 460),
                    child: ClipRect(
                      child: OverflowBox(
                        alignment: Alignment.topCenter,
                        maxHeight: double.infinity,
                        child: _cards(page),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _wordsFor(_Stage stage, double space, String? email) {
    final theme = Theme.of(context);
    final (title, line) = _words[stage]!;
    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(24, space + 20, 24, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(title, style: theme.textTheme.headlineLarge),
          const SizedBox(height: 8),
          Text(
            line,
            style: theme.textTheme.bodyLarge?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          if (stage == _Stage.sync) ...[
            const SizedBox(height: 24),
            if (email == null)
              ..._signIn(context)
            else
              Text(
                'Signed in as $email · recipes sync',
                style: theme.textTheme.titleSmall,
              ),
          ],
          if (stage == _Stage.create) ..._composer(),
        ],
      ),
    );
  }

  List<Widget> _composer() {
    final theme = Theme.of(context);
    if (_writing case final verbs?) {
      return [const SizedBox(height: 28), Writing(verbs)];
    }
    if (_written case final written?) {
      return [
        const SizedBox(height: 20),
        Text('${written.title} is ready.', style: theme.textTheme.titleSmall),
      ];
    }
    return [
      const SizedBox(height: 20),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final (tier, dish) in _ideas)
            _IdeaChip(
              tier: tier,
              dish: dish,
              picked: _idea.text == dish,
              onTap: () => setState(() => _idea.text = dish),
            ),
        ],
      ),
      const SizedBox(height: 12),
      TextField(
        controller: _idea,
        onChanged: (_) => setState(() {}),
        onSubmitted: (_) => _write(),
        textInputAction: TextInputAction.send,
        textCapitalization: TextCapitalization.sentences,
        decoration: InputDecoration(
          hintText: 'Or say what you feel like eating',
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(24),
            borderSide: BorderSide.none,
          ),
        ),
      ),
      if (_failed case final failed?) ...[
        const SizedBox(height: 12),
        Text(
          'Couldn\'t write that one, so the focaccia stays. $failed',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.error,
          ),
        ),
      ],
    ];
  }

  Widget _buttons(bool signedOut) {
    final busy = _writing != null;
    final (String label, VoidCallback? onPressed) = switch (_stage) {
      _Stage.create when _written != null => ('Done', () => _finish(_written)),
      _Stage.create => (
        'Write it',
        busy || _idea.text.trim().isEmpty ? null : _write,
      ),
      _Stage.keep => ('Done', () => _finish(sampleRecipe)),
      _ when signedOut => ('Not now', _next),
      _ => (_last ? 'Done' : 'Next', _next),
    };
    final (String, VoidCallback?)? second = switch (_stage) {
      _Stage.create when _written == null => (
        'Keep the focaccia',
        busy ? null : () => _finish(sampleRecipe),
      ),
      _ when !_last => ('Skip', () => Navigator.pop(context)),
      _ => null,
    };
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FilledButton(
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(56)),
          onPressed: onPressed,
          child: Text(label),
        ),
        if (second case (final label, final onPressed))
          TextButton(
            style: TextButton.styleFrom(minimumSize: const Size.fromHeight(48)),
            onPressed: onPressed,
            child: Text(label),
          ),
      ],
    );
  }

  /// The card, and on the sync page a second copy of it sliding out from
  /// behind: the same recipe on another phone.
  Widget _cards(double page) {
    final sync = _at(_Stage.sync, page);
    // The cook's own recipe only on its own page; swiping back shows the
    // focaccia the other pages are about.
    final recipe = _stage == _Stage.create && _written != null
        ? _written!
        : sampleRecipe;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        if (sync > 0)
          Positioned.fill(
            // Shorter than the front card at the same top, so only its
            // right edge shows: no second title peeking out underneath.
            child: Transform.scale(
              scale: 1 - 0.2 * sync,
              alignment: Alignment.centerRight,
              child: Opacity(opacity: sync, child: _card(sampleRecipe, page)),
            ),
          ),
        Transform.scale(
          scale: 1 - 0.14 * sync,
          alignment: Alignment.topLeft,
          child: AnimatedSwitcher(
            duration: _motion(500),
            transitionBuilder: (child, animation) => FadeTransition(
              opacity: animation,
              child: ScaleTransition(
                scale: Tween(begin: 0.96, end: 1.0).animate(animation),
                child: child,
              ),
            ),
            child: KeyedSubtree(
              key: ObjectKey(recipe),
              child: _card(recipe, page),
            ),
          ),
        ),
      ],
    );
  }

  Widget _card(Recipe recipe, double page) {
    final theme = Theme.of(context);
    final compact = _at(_Stage.create, page) + _at(_Stage.keep, page);
    final photo = 72 + 128 * _at(_Stage.photo, page) + 48 * compact;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(panelRadius),
        border: Border.all(color: glassRim(context)),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(panelRadius),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              height: photo,
              child: _photo(recipe, _at(_Stage.photo, page)),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    recipe.tags.join('  ·  '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style:
                        weighted(
                          theme.textTheme.labelMedium,
                          FontWeight.w600,
                        )?.copyWith(
                          color: theme.colorScheme.primary,
                          letterSpacing: 1.1,
                        ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    recipe.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.headlineSmall,
                  ),
                  // Always in the tree, only folded away: each one's
                  // animation keeps its state from page to page.
                  _reveal(_at(_Stage.scale, page), _scaling()),
                  _reveal(_at(_Stage.log, page), _cooked()),
                  _reveal(
                    compact,
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        '${countLabel(recipe, baseCount(recipe))}  ·  '
                        '${recipe.ingredients.length} ingredients  ·  '
                        '${recipe.steps.length} steps',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _reveal(double t, Widget child) => ClipRect(
    child: Align(
      alignment: Alignment.topCenter,
      heightFactor: t,
      child: Opacity(opacity: t, child: child),
    ),
  );

  /// The bundled photo, or for a written recipe the list's generated art. The
  /// credit shows on the photo page, where it is what the page is about.
  Widget _photo(Recipe recipe, double credit) {
    final accent = tagAccent(context, recipe.tags);
    final art = DecoratedBox(
      decoration: BoxDecoration(gradient: coverGradient(accent)),
      child: Center(
        child: Text(
          recipe.title.characters.first.toUpperCase(),
          style: serif(44).copyWith(color: onAccent(accent)),
        ),
      ),
    );
    final name = recipe.imageCredit?.name;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: _motion(700),
      curve: Curves.easeOutCubic,
      builder: (context, t, child) => Opacity(
        opacity: t,
        child: Transform.scale(scale: 1.08 - 0.08 * t, child: child),
      ),
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (identical(recipe, sampleRecipe))
            Image.asset(
              samplePhotoAsset,
              fit: BoxFit.cover,
              errorBuilder: (_, _, _) => art,
            )
          else
            art,
          if (name != null && credit > 0) ...[
            Opacity(
              opacity: credit,
              child: const DecoratedBox(
                decoration: BoxDecoration(gradient: heroScrim),
              ),
            ),
            Positioned(
              left: 14,
              right: 14,
              bottom: 10,
              child: Opacity(
                opacity: credit,
                child: Text(
                  'Photo by $name on Unsplash',
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: Colors.white.withValues(alpha: 0.9),
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// The stepper, two amounts and the first step, all at the stepper's
  /// count. Amounts roll to it rather than jump, so a change is seen to
  /// travel; when the first roll lands, the flour switches units.
  Widget _scaling() {
    final theme = Theme.of(context);
    final recipe = sampleRecipe;
    final accent = theme.colorScheme.primary;
    final amount = weighted(
      theme.textTheme.bodyMedium,
      FontWeight.w600,
    )?.copyWith(color: accent);
    final flipped = _flipped ? const {'0001'} : const <String>{};
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  countLabel(recipe, _count),
                  style: theme.textTheme.titleSmall,
                ),
              ),
              IconButton(
                onPressed: _count > 1 ? () => setState(() => _count--) : null,
                icon: const Icon(Icons.remove),
                color: accent,
                tooltip: 'Fewer',
              ),
              IconButton(
                onPressed: () => setState(() => _count++),
                icon: const Icon(Icons.add),
                color: accent,
                tooltip: 'More',
              ),
            ],
          ),
          TweenAnimationBuilder<double>(
            tween: Tween(end: scaleFactor(recipe, _count)),
            duration: _motion(900),
            curve: Curves.easeInOutCubic,
            onEnd: () {
              if (!_flipped) setState(() => _flipped = true);
            },
            builder: (context, factor, _) => Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final i in recipe.ingredients.take(2))
                  AnimatedContainer(
                    duration: _motion(300),
                    margin: const EdgeInsets.only(bottom: 2),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      // The band the detail screen uses for a computed amount.
                      color: isDerived(i, flip: flipped.contains(i.id))
                          ? herbWash(context)
                          : Colors.transparent,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Row(
                      children: [
                        SizedBox(
                          width: 96,
                          child: AnimatedSwitcher(
                            duration: _motion(300),
                            child: Text(
                              amountLabel(
                                i,
                                factor,
                                flip: flipped.contains(i.id),
                              ),
                              key: ValueKey(flipped.contains(i.id)),
                              style: amount,
                            ),
                          ),
                        ),
                        Expanded(
                          child: Text(
                            i.name,
                            style: theme.textTheme.bodyMedium,
                          ),
                        ),
                      ],
                    ),
                  ),
                const SizedBox(height: 6),
                Text.rich(
                  TextSpan(
                    children: [
                      for (final part in contentParts(
                        recipe.steps.first,
                        recipe,
                        factor,
                        flipped: flipped,
                      ))
                        part.amount == null
                            ? TextSpan(text: part.text)
                            : TextSpan(
                                text: '${part.amount} ${part.text}',
                                style: amount,
                              ),
                    ],
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Five stars filling in one after another, the first time the page lands.
  Widget _cooked() {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TweenAnimationBuilder<double>(
            tween: Tween(begin: 0, end: _landed.contains(_Stage.log) ? 5 : 0),
            duration: _motion(900),
            builder: (context, filled, _) => Row(
              children: [
                for (var i = 0; i < 5; i++)
                  Builder(
                    builder: (context) {
                      final t = (filled - i).clamp(0.0, 1.0);
                      return Transform.scale(
                        // A pop as each one fills.
                        scale: 1 + 1.4 * t * (1 - t),
                        child: Icon(
                          t > 0.5
                              ? Icons.star_rounded
                              : Icons.star_outline_rounded,
                          color: theme.colorScheme.primary,
                          size: 24,
                        ),
                      );
                    },
                  ),
              ],
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Made 2 loaves  ·  softer with the cold proof',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  /// Settings' two buttons: each links the provider to the anonymous user
  /// this install already has, so nothing moves.
  List<Widget> _signIn(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return [
      OutlinedButton(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size.fromHeight(50),
          side: BorderSide(color: glassRim(context)),
          foregroundColor: scheme.onSurface,
          backgroundColor: scheme.surface,
        ),
        onPressed: () => runAccountAction(context, signInWithGoogle),
        child: const Text('Continue with Google'),
      ),
      // Apple's own rule: offering Google on iOS means offering Apple too.
      if (Platform.isIOS) ...[
        const SizedBox(height: 10),
        FilledButton(
          style: FilledButton.styleFrom(
            minimumSize: const Size.fromHeight(50),
            backgroundColor: scheme.onSurface,
            foregroundColor: scheme.surface,
          ),
          onPressed: () => runAccountAction(context, signInWithApple),
          child: const Text('Continue with Apple'),
        ),
      ],
    ];
  }
}

/// One of the ideas under the composer: how big a job, then the dish.
class _IdeaChip extends StatelessWidget {
  final String tier;
  final String dish;
  final bool picked;
  final VoidCallback onTap;

  const _IdeaChip({
    required this.tier,
    required this.dish,
    required this.picked,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: picked ? herbWash(context) : glassFill(context),
      borderRadius: BorderRadius.circular(pillRadius),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(pillRadius),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 8, 14, 10),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                tier.toUpperCase(),
                style: weighted(theme.textTheme.labelSmall, FontWeight.w600)
                    ?.copyWith(
                      color: theme.colorScheme.primary,
                      letterSpacing: 1.1,
                    ),
              ),
              Text(dish, style: theme.textTheme.bodyMedium),
            ],
          ),
        ),
      ),
    );
  }
}

/// What a skipped tour still owes — the sign-in page, then Pro — shown once,
/// the first time the cook comes back to the list from a recipe: by then they
/// have seen what an account would be keeping. Recorded before it opens, so
/// leaving it any way at all counts as shown.
Future<void> showOwedOnboarding(BuildContext context, RecipeStore store) async {
  await store.setOnboarding('done');
  if (!context.mounted) return;
  final signIn = accountsOn && account.value?.email == null;
  final pro = proOn && proUntil.value == null;
  if (signIn) {
    await Navigator.push(
      context,
      MaterialPageRoute<Object?>(
        builder: (_) => OnboardingScreen(store: store, followUp: true),
      ),
    );
  } else if (pro) {
    await Navigator.push(
      context,
      MaterialPageRoute<bool>(builder: (_) => const ProScreen()),
    );
  }
}
