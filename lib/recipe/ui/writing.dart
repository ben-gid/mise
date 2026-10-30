import 'dart:async';

import 'package:flutter/material.dart';

import 'glass.dart';

/// Verbs for a dish, keyed by words that name it. First match wins, so the
/// showpieces come before the cakes they contain ("mousse cake").
// ponytail: substring match, so "pie" also hits "piece". A wrong match only
// costs a less fitting verb; a model would cost a dependency.
const _byDish = <(List<String>, List<String>)>[
  (
    ['entremet', 'mousse', 'souffl', 'croissant', 'macaron', 'gateau', 'tuile'],
    [
      'Tempering the chocolate…',
      'Laminating…',
      'Setting the mousse…',
      'Glazing…',
    ],
  ),
  (
    ['smoothie', 'shake', 'juice', 'lassi'],
    ['Peeling the fruit…', 'Blending…', 'Chilling the glasses…'],
  ),
  (
    ['cake', 'cookie', 'brownie', 'muffin', 'tart', 'pie', 'bread', 'loaf'],
    [
      'Creaming the butter…',
      'Folding in the flour…',
      'Preheating the oven…',
      'Proofing…',
    ],
  ),
  (
    ['curry', 'stew', 'soup', 'braise', 'chili', 'dal', 'ragu', 'ramen'],
    [
      'Toasting the spices…',
      'Sweating the onions…',
      'Simmering…',
      'Tasting for salt…',
    ],
  ),
  (
    ['pasta', 'noodle', 'risotto', 'gnocchi', 'lasagn', 'spaghetti'],
    ['Salting the water…', 'Stirring…', 'Grating the cheese…'],
  ),
  (
    ['salad', 'bowl', 'slaw'],
    ['Chopping…', 'Whisking the dressing…', 'Tossing…'],
  ),
  (
    ['steak', 'grill', 'bbq', 'roast', 'chicken', 'pork', 'lamb', 'fish'],
    ['Heating the pan…', 'Searing…', 'Resting the meat…'],
  ),
];

const _anyDish = [
  'Reading your idea…',
  'Whisking…',
  'Seasoning…',
  'Tasting…',
  'Plating…',
];

/// What [Writing] says while a recipe for [idea] is written.
List<String> verbsFor(String idea) {
  final words = idea.toLowerCase();
  for (final (keys, verbs) in _byDish) {
    if (keys.any(words.contains)) return verbs;
  }
  return _anyDish;
}

/// What [Writing] says while an import is read: a page or a photo.
List<String> readingVerbs(String what) => [
  'Reading the $what…',
  'Finding the ingredients…',
  'Checking the amounts…',
];

/// The wait for the server: [verbs] in turn over a sweeping bar. It animates
/// forever, so it is only ever up while a real request is out — never in a
/// test, where the server is off.
class Writing extends StatefulWidget {
  final List<String> verbs;

  const Writing(this.verbs, {super.key});

  @override
  State<Writing> createState() => _WritingState();
}

class _WritingState extends State<Writing> with SingleTickerProviderStateMixin {
  late final _sweep = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  )..repeat();
  late final Timer _turn;
  int _at = 0;

  @override
  void initState() {
    super.initState();
    _turn = Timer.periodic(const Duration(milliseconds: 1800), (_) {
      if (widget.verbs.length > 1) setState(() => _at++);
    });
  }

  @override
  void dispose() {
    _turn.cancel();
    _sweep.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = theme.colorScheme.primary;
    // Reduce Motion keeps the words (a dissolve is fine) and stills the bar.
    final still = MediaQuery.disableAnimationsOf(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 350),
          transitionBuilder: (child, animation) => FadeTransition(
            opacity: animation,
            child: SlideTransition(
              position: Tween(
                begin: Offset(0, still ? 0 : 0.4),
                end: Offset.zero,
              ).animate(animation),
              child: child,
            ),
          ),
          layoutBuilder: (current, previous) => Stack(
            alignment: AlignmentDirectional.centerStart,
            children: [...previous, ?current],
          ),
          child: Text(
            widget.verbs[_at % widget.verbs.length],
            key: ValueKey(_at),
            style: theme.textTheme.bodyLarge,
          ),
        ),
        const SizedBox(height: 10),
        ClipRRect(
          borderRadius: BorderRadius.circular(2),
          child: SizedBox(
            height: 3,
            width: 200,
            child: ColoredBox(
              color: glassRim(context),
              child: still
                  ? ColoredBox(color: accent.withValues(alpha: 0.5))
                  : AnimatedBuilder(
                      animation: _sweep,
                      builder: (context, _) => Align(
                        alignment: Alignment(-1.8 + 3.6 * _sweep.value, 0),
                        child: FractionallySizedBox(
                          widthFactor: 0.45,
                          heightFactor: 1,
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                colors: [
                                  accent.withValues(alpha: 0),
                                  accent,
                                  accent.withValues(alpha: 0),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
            ),
          ),
        ),
      ],
    );
  }
}
