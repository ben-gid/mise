import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

/// "Fogged Window" — the app's visual identity.
///
/// A dark kitchen at night: a static ember glow low on the screen, cool violet
/// above, and glass panels standing in for the wiped-clear patches on a steamed
/// pane. The backdrop is generated rather than photographic, and on the detail
/// screen it takes its hue from the recipe's own tags.
///
/// A recipe carrying a photo is the one place there is something real behind
/// the glass: the detail screen's hero scrolls up under [frostPane], whose blur
/// finally has an image to fog rather than a gradient to smooth.
///
/// Two rules hold this together and are easy to break by accident:
///
/// 1. **Blur once per screen.** A [BackdropFilter] per card is one blur pass per
///    card per frame and will jank under Impeller. [frostPane] is the only
///    thing that filters; [GlassPanel] is a flat translucent fill over the
///    gradient.
/// 2. **Nothing animates on its own.** An indefinite animation hangs
///    `pumpAndSettle` in widget tests (see CLAUDE.md), so the backdrop is
///    static. The only motion here is the finite amount crossfade on the
///    detail screen.

// ---------------------------------------------------------------------------
// Tokens
// ---------------------------------------------------------------------------

const _ink = Color(0xFF0E0B10); // page floor, near-black plum
const _haze = Color(0xFF2B2140); // cool violet, upper backdrop
const _ember = Color(0xFFFF6B3D); // accent: amounts, FAB, timers, active
const _dough = Color(0xFFF2E4CE); // primary text, warm off-white

const _plaster = Color(0xFFF3EDE4); // page floor, light
const _hazeLight = Color(0xFFDCD4E4); // violet wash, light
const _emberDeep = Color(0xFFC4471C); // accent darkened to hold contrast
const _slate = Color(0xFF231C1A); // primary text, light

/// Panels and cards. Chips, pills and fields use [pillRadius].
const panelRadius = 18.0;
const pillRadius = 12.0;

bool _isDark(BuildContext context) =>
    Theme.of(context).brightness == Brightness.dark;

/// Panel fill. Opaque enough that body text keeps its contrast over the
/// brightest point of the backdrop — translucency you can see, not translucency
/// you have to read through.
Color glassFill(BuildContext context) => _isDark(context)
    ? _dough.withValues(alpha: 0.08)
    : Colors.white.withValues(alpha: 0.55);

/// The hairline that catches the light along a panel's edge.
Color glassRim(BuildContext context) => _isDark(context)
    ? _dough.withValues(alpha: 0.20)
    : Colors.white.withValues(alpha: 0.85);

// ---------------------------------------------------------------------------
// Tag Prism
// ---------------------------------------------------------------------------

/// Hues for tags common enough to be worth naming. Everything else is derived,
/// so every recipe still gets its own light.
/// Diff colours for the history screen: a brick red and a moss green. Both are
/// pushed warm — the red towards clay rather than crimson, the green towards
/// yellow rather than emerald — so they belong to this app's ember ground
/// instead of reading as a pasted terminal, but carry enough chroma to be read
/// across a room. Never the only signal: the gutter marker and the badge icon
/// say the same thing without colour.
///
/// Both light values clear 4.5:1 on the plaster ground, with headroom for the
/// tint [diffBand] lays under them.
Color diffRemoved(BuildContext context) =>
    _isDark(context) ? const Color(0xFFF8685C) : const Color(0xFFC1271B);

Color diffAdded(BuildContext context) =>
    _isDark(context) ? const Color(0xFF7BD168) : const Color(0xFF367326);

/// A value that was swapped rather than added or dropped. Drawn from the haze
/// family the backdrop already uses, so it separates from the warm red and
/// green by temperature without importing a blue from outside the palette.
Color diffChanged(BuildContext context) =>
    _isDark(context) ? const Color(0xFFB9A5E8) : const Color(0xFF4B3A78);

/// The band behind a diff line. Light enough that body text stays the thing
/// being read.
Color diffBand(BuildContext context, Color line) =>
    line.withValues(alpha: _isDark(context) ? 0.14 : 0.10);

const _tagHues = <String, double>{
  'bread': 38, // wheat gold
  'baking': 38,
  'dessert': 330, // berry
  'sweet': 330,
  'spicy': 8, // ember red
  'seafood': 190,
  'vegetarian': 96,
  'vegan': 96,
  'breakfast': 48,
  'soup': 24,
  'salad': 110,
  'drink': 205,
};

/// The colour a recipe is remembered by, derived from its first tag.
///
/// Tags are the only per-recipe axis the model gives us, so they do the
/// wayfinding rather than sitting in the corner as grey chips. Untagged recipes
/// fall back to the house ember.
///
/// The derived hue sums code units rather than using [String.hashCode]: the
/// latter is not specified stable across SDK versions, and a backdrop that
/// silently shifts hue after a Flutter upgrade is a miserable bug to chase.
Color tagAccent(BuildContext context, List<String> tags) {
  final dark = _isDark(context);
  if (tags.isEmpty) return dark ? _ember : _emberDeep;
  final tag = tags.first.toLowerCase();
  final hue =
      _tagHues[tag] ??
      (tag.codeUnits.fold(0, (sum, unit) => sum + unit) % 360).toDouble();
  return HSLColor.fromAHSL(
    1,
    hue,
    dark ? 0.72 : 0.62,
    dark ? 0.58 : 0.38,
  ).toColor();
}

/// Ink for text sitting on a solid [tagAccent] fill. Derived rather than fixed,
/// because the accent hue is derived too and can land either side of readable.
Color onAccent(Color accent) =>
    accent.computeLuminance() > 0.45 ? _slate : Colors.white;

// ---------------------------------------------------------------------------
// Structure
// ---------------------------------------------------------------------------

/// A [Scaffold] over the generated backdrop.
///
/// Pass [tint] to colour the glow — the detail screen passes [tagAccent] so each
/// recipe arrives with its own light. The body sits behind the app bar, so
/// scrollable children need to add [glassAppBarInset] to their top padding.
class GlassScaffold extends StatelessWidget {
  final Color? tint;
  final PreferredSizeWidget? appBar;
  final Widget? floatingActionButton;
  final Widget body;

  const GlassScaffold({
    super.key,
    this.tint,
    this.appBar,
    this.floatingActionButton,
    required this.body,
  });

  @override
  Widget build(BuildContext context) {
    final dark = _isDark(context);
    final glow = tint ?? (dark ? _ember : _emberDeep);
    return Stack(
      children: [
        Positioned.fill(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: dark
                    ? const [_haze, _ink]
                    : const [_hazeLight, _plaster],
              ),
            ),
          ),
        ),
        // The ember on the stove. Capped low: this alpha is the ceiling that
        // keeps a panel sitting over the brightest point still readable.
        Positioned.fill(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: RadialGradient(
                center: const Alignment(0, 1.15),
                radius: 1.1,
                colors: [
                  glow.withValues(alpha: dark ? 0.35 : 0.20),
                  glow.withValues(alpha: 0),
                ],
              ),
            ),
          ),
        ),
        Scaffold(
          backgroundColor: Colors.transparent,
          extendBodyBehindAppBar: true,
          appBar: appBar,
          floatingActionButton: floatingActionButton,
          body: body,
        ),
      ],
    );
  }
}

/// Top padding a scrollable needs to clear the app bar it scrolls under.
///
/// Call this from the screen's own build context, above [GlassScaffold] — not
/// from a builder nested inside the body. `extendBodyBehindAppBar` makes the
/// Scaffold report the app bar's whole height as `MediaQuery.padding.top` to
/// the body, so read from in there this adds [kToolbarHeight] to a figure that
/// already includes it and opens a bar-sized gap under the bar.
double glassAppBarInset(BuildContext context) =>
    MediaQuery.paddingOf(context).top + kToolbarHeight;

/// The one blurred surface in the app — content genuinely passes under it.
///
/// [opacity] ramps the whole pane, blur included, so the detail screen's hero
/// can fog in as it collapses. At 0 the sigma is 0 too: a pane that isn't
/// fogging shouldn't be paying for a blur pass either.
///
/// Deliberately not an animation. The hero drives this straight off its own
/// layout extent, so the fog is a function of scroll position with no
/// controller to dispose and nothing for `pumpAndSettle` to wait on.
Widget frostPane(BuildContext context, {double opacity = 1}) {
  final fill = glassFill(context);
  final rim = glassRim(context);
  return ClipRect(
    child: BackdropFilter(
      filter: ImageFilter.blur(sigmaX: 18 * opacity, sigmaY: 18 * opacity),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: fill.withValues(alpha: fill.a * opacity),
          border: Border(
            bottom: BorderSide(color: rim.withValues(alpha: rim.a * opacity)),
          ),
        ),
        child: const SizedBox.expand(),
      ),
    ),
  );
}

/// The art a recipe falls back to when it has no photo, or when the one it
/// names won't load: its own tag hue, lit from the top left.
///
/// Shared so a dead url degrades to exactly what an imageless recipe already
/// shows, rather than to a second, slightly different placeholder.
LinearGradient coverGradient(Color accent) => LinearGradient(
  begin: Alignment.topLeft,
  end: Alignment.bottomRight,
  colors: [
    accent,
    Color.alphaBlend(Colors.black.withValues(alpha: 0.28), accent),
  ],
);

/// The wash over a hero photo, so a title stays readable on any picture.
///
/// Deepened toward the page floor rather than to neutral black, and carrying
/// the recipe's own [tagAccent]. Every other surface here is lit by that hue —
/// the backdrop, the amounts, the stars, the step numbers — so a neutral scrim
/// would switch the recipe's colour off at the one place it is most itself, and
/// would leave the hero reading as a rectangle pasted above the gradient rather
/// than continuous with it. Kept to a cast rather than a wash: the photograph
/// is still the thing being looked at.
///
/// Weighted at the **top**, where the toolbar's icons sit. The recipe's name is
/// set in the page body rather than over the picture, so the bottom needs only
/// enough to carry the credit line — anything heavier is a third of a
/// photograph darkened for nothing.
LinearGradient heroScrim(BuildContext context, Color accent) {
  final floor = _isDark(context) ? _ink : _slate;
  final tinted = Color.alphaBlend(accent.withValues(alpha: 0.30), floor);
  return LinearGradient(
    begin: Alignment.bottomCenter,
    end: Alignment.topCenter,
    colors: [
      tinted.withValues(alpha: 0.55),
      tinted.withValues(alpha: 0.15),
      tinted.withValues(alpha: 0.06),
      tinted.withValues(alpha: 0.45),
    ],
    stops: const [0, 0.28, 0.60, 1],
  );
}

PreferredSizeWidget glassAppBar(
  BuildContext context, {
  required Widget title,
  List<Widget>? actions,
}) {
  return AppBar(
    title: title,
    actions: actions,
    flexibleSpace: frostPane(context),
  );
}

/// A frosted panel. Flat fill, no blur of its own — see the class docs above.
///
/// [edge] paints a colour strip down the left side, which is how the list
/// screen echoes a recipe's tag hue. It is a child rather than a
/// [Border] because a [BoxDecoration] asserts on a non-uniform border combined
/// with a border radius.
class GlassPanel extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry? margin;
  final Color? edge;
  final Color? fill;

  const GlassPanel({
    super.key,
    required this.child,
    this.margin,
    this.edge,
    this.fill,
  });

  @override
  Widget build(BuildContext context) {
    final base = fill ?? glassFill(context);
    return Container(
      // Dismissible wraps its child in a loose Stack, so a panel inside one is
      // handed loose width and would shrink to its content. Fill the width we
      // are offered instead of measuring it.
      width: double.infinity,
      margin: margin,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        // A touch brighter along the top edge, the way light sits on glass.
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Color.alphaBlend(glassRim(context).withValues(alpha: 0.10), base),
            base,
          ],
        ),
        borderRadius: BorderRadius.circular(panelRadius),
        border: Border.all(color: glassRim(context)),
        // On dark the rim alone separates a panel from the ground. On light
        // there is nothing for a white rim to push against, so it needs a soft
        // drop instead.
        boxShadow: _isDark(context)
            ? null
            : [
                BoxShadow(
                  color: _slate.withValues(alpha: 0.10),
                  blurRadius: 18,
                  offset: const Offset(0, 6),
                ),
              ],
      ),
      // Transparent Material so InkWell splashes paint above the fill instead
      // of behind it on the Scaffold's Material.
      child: Material(
        type: MaterialType.transparency,
        child: edge == null
            ? child
            // Stack, not Row: panels live in a ListView, so their height is
            // unbounded, and a stretched Row would resolve to infinity. Here
            // the content sizes the panel and the strip stretches to match.
            : Stack(
                // Non-positioned children would otherwise be loosely
                // constrained and shrink to their intrinsic width.
                fit: StackFit.passthrough,
                children: [
                  child,
                  Positioned(
                    top: 0,
                    bottom: 0,
                    left: 0,
                    width: 3,
                    child: ColoredBox(color: edge!),
                  ),
                ],
              ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Themes
// ---------------------------------------------------------------------------

/// Titles only. A wide low-contrast grotesque survives on translucent surfaces,
/// where a hairline serif would dissolve into the blur.
///
/// Weights come from the variable font's axes rather than from shipping a
/// static cut per weight; `opsz` is clamped to the axis range the file declares.
TextStyle _display(double size, double weight) => TextStyle(
  fontFamily: 'Bricolage',
  fontSize: size,
  height: 1.15,
  letterSpacing: -0.4,
  fontVariations: [
    FontVariation('wght', weight),
    FontVariation('opsz', size.clamp(12, 72)),
  ],
);

TextTheme _textTheme(TextTheme base) => base.copyWith(
  // The recipe's own name, and the only call that takes `opsz` anywhere near
  // the range it was clamped for — everything else here sits at 18 or 24.
  headlineMedium: base.headlineMedium?.merge(_display(34, 640)),
  titleLarge: base.titleLarge?.merge(_display(24, 620)),
  titleMedium: base.titleMedium?.merge(_display(18, 600)),
);

ThemeData _theme(ColorScheme scheme) {
  final base = ThemeData(colorScheme: scheme);
  final rim = scheme.brightness == Brightness.dark
      ? _dough.withValues(alpha: 0.20)
      : Colors.white.withValues(alpha: 0.85);
  final fill = scheme.brightness == Brightness.dark
      ? _dough.withValues(alpha: 0.08)
      : Colors.white.withValues(alpha: 0.55);

  return base.copyWith(
    textTheme: _textTheme(base.textTheme),
    // Transparent so GlassScaffold's gradient shows through; the blur lives in
    // glassAppBar's flexibleSpace.
    appBarTheme: AppBarTheme(
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      scrolledUnderElevation: 0,
      elevation: 0,
      foregroundColor: scheme.onSurface,
      titleTextStyle: _textTheme(base.textTheme).titleLarge,
    ),
    chipTheme: ChipThemeData(
      backgroundColor: fill,
      side: BorderSide(color: rim),
      labelStyle: base.textTheme.labelMedium?.copyWith(
        color: scheme.onSurfaceVariant,
      ),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(pillRadius),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: fill,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(pillRadius),
        borderSide: BorderSide(color: rim),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(pillRadius),
        borderSide: BorderSide(color: rim),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(pillRadius),
        borderSide: BorderSide(color: scheme.primary, width: 2),
      ),
    ),
    floatingActionButtonTheme: FloatingActionButtonThemeData(
      backgroundColor: scheme.primary,
      foregroundColor: scheme.onPrimary,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(pillRadius),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(pillRadius),
      ),
    ),
  );
}

const _darkScheme = ColorScheme(
  brightness: Brightness.dark,
  primary: _ember,
  onPrimary: Color(0xFF2A0E04),
  primaryContainer: Color(0xFF40200F),
  onPrimaryContainer: Color(0xFFFFD9C7),
  secondary: Color(0xFF9C8AA8),
  onSecondary: Color(0xFF1E1626),
  secondaryContainer: Color(0xFF33283F),
  onSecondaryContainer: Color(0xFFE4D9EC),
  error: Color(0xFFFF8A80),
  onError: Color(0xFF3B0A08),
  errorContainer: Color(0xFF4D1F1C),
  onErrorContainer: Color(0xFFFFDAD4),
  surface: _ink,
  onSurface: _dough,
  onSurfaceVariant: Color(0xFFC4B5A4),
  outline: Color(0xFF8A7C6E),
  outlineVariant: Color(0xFF3A3239),
);

const _lightScheme = ColorScheme(
  brightness: Brightness.light,
  primary: _emberDeep,
  onPrimary: Color(0xFFFFFFFF),
  primaryContainer: Color(0xFFFFDBCD),
  onPrimaryContainer: Color(0xFF3D1206),
  secondary: Color(0xFF5D5470),
  onSecondary: Color(0xFFFFFFFF),
  secondaryContainer: Color(0xFFE5DCF0),
  onSecondaryContainer: Color(0xFF1E1626),
  error: Color(0xFFB3261E),
  onError: Color(0xFFFFFFFF),
  errorContainer: Color(0xFFF9DEDC),
  onErrorContainer: Color(0xFF410E0B),
  surface: _plaster,
  onSurface: _slate,
  onSurfaceVariant: Color(0xFF574E48),
  outline: Color(0xFF8A7F77),
  outlineVariant: Color(0xFFD6CCC2),
);

abstract final class AppTheme {
  static ThemeData get dark => _theme(_darkScheme);
  static ThemeData get light => _theme(_lightScheme);
}

/// The chosen theme. One notifier rather than an InheritedWidget: `main()`
/// listens, the settings screen writes, nothing in between needs to know. It is
/// seeded from `RecipeStore.themeName` at startup and written back on change.
final themeMode = ValueNotifier(ThemeMode.system);
