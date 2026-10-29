import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// "Spread" — the app's visual identity.
///
/// A magazine spread rather than a fogged window: a plain white page, herb
/// green for the things you act on, Instrument Serif for names and numerals
/// and Geist for everything you read. The photo the app finds does the
/// decorating, so every other surface stays flat and quiet.
///
/// The file keeps its old name and the `glass*` helpers keep theirs so the
/// screens not yet redrawn compile unchanged; they now paint flat. Real glass
/// is [frost], and only for controls floating over the page.
///
/// One rule carries over and is easy to break by accident: **nothing animates
/// on its own.** An indefinite animation hangs `pumpAndSettle` in widget tests
/// (see CLAUDE.md).

// ---------------------------------------------------------------------------
// Tokens
// ---------------------------------------------------------------------------

const _paper = Color(0xFFFFFFFF); // page, light
const _wash = Color(0xFFF4F4F1); // fields, panels, the cook log band
const _ink = Color(0xFF161616); // primary text, light
const _muted = Color(0xFF63625E); // secondary text, light
const _rule = Color(0xFFE4E3DF); // hairlines, light
const _herb = Color(0xFF2E5B3B); // accent: amounts, buttons, numerals
const _herbWash = Color(0xFFEAF1EB); // derived-amount band, quiet chips

const _night = Color(0xFF121311); // page, dark
const _nightWash = Color(0xFF1E1F1C);
const _moon = Color(0xFFEDECE7); // primary text, dark
const _moonMuted = Color(0xFFA6A49E);
const _nightRule = Color(0xFF2F302D);
const _herbLight = Color(0xFF8CC49B); // accent lifted to hold contrast on night
const _herbNight = Color(0xFF1F2B22);

/// Panels and cards. Chips, pills and fields use [pillRadius].
const panelRadius = 18.0;
const pillRadius = 14.0;

bool _isDark(BuildContext context) =>
    Theme.of(context).brightness == Brightness.dark;

/// Panel fill: the wash a field or card sits on, solid in both themes.
Color glassFill(BuildContext context) => _isDark(context) ? _nightWash : _wash;

/// The hairline between rows.
Color glassRim(BuildContext context) => _isDark(context) ? _nightRule : _rule;

/// The band behind an amount computed through a density rather than read as
/// stored. Also the fill for quiet herb chips.
Color herbWash(BuildContext context) =>
    _isDark(context) ? _herbNight : _herbWash;

/// Geist is one variable file, and a variable font ignores [FontWeight] unless
/// the `wght` axis is set to match — so every weight change goes through here.
TextStyle? weighted(TextStyle? style, FontWeight weight) => style?.copyWith(
  fontWeight: weight,
  fontVariations: [FontVariation('wght', weight.value.toDouble())],
);

/// Diff colours for the history screen: herb for what arrived, brick for what
/// left, violet for what was swapped. Never the only signal: the gutter marker
/// and the badge icon say the same thing without colour.
Color diffRemoved(BuildContext context) =>
    _isDark(context) ? const Color(0xFFF08A73) : const Color(0xFFA8321F);

Color diffAdded(BuildContext context) => _isDark(context) ? _herbLight : _herb;

Color diffChanged(BuildContext context) =>
    _isDark(context) ? const Color(0xFFB9A5E8) : const Color(0xFF4B3A78);

/// The band behind a diff line. Light enough that body text stays the thing
/// being read.
Color diffBand(BuildContext context, Color line) =>
    line.withValues(alpha: _isDark(context) ? 0.14 : 0.09);

// ---------------------------------------------------------------------------
// Generated cover art
// ---------------------------------------------------------------------------

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

/// The colour of a recipe's generated cover — what a list tile shows while its
/// photo is being found, and for good when there is none. Taken from its first
/// tag so two photo-less recipes still look different.
///
/// Muted on purpose: everywhere else the page is white and herb, and a
/// saturated tile would be the loudest thing in the library.
///
/// The derived hue sums code units rather than using [String.hashCode]: the
/// latter is not specified stable across SDK versions, and a cover that
/// silently shifts hue after a Flutter upgrade is a miserable bug to chase.
Color tagAccent(BuildContext context, List<String> tags) {
  final dark = _isDark(context);
  if (tags.isEmpty) return dark ? const Color(0xFF4C6B55) : _herb;
  final tag = tags.first.toLowerCase();
  final hue =
      _tagHues[tag] ??
      (tag.codeUnits.fold(0, (sum, unit) => sum + unit) % 360).toDouble();
  return HSLColor.fromAHSL(1, hue, 0.38, dark ? 0.36 : 0.52).toColor();
}

/// Ink for text sitting on a solid [tagAccent] fill. Derived rather than fixed,
/// because the accent hue is derived too and can land either side of readable.
Color onAccent(Color accent) =>
    accent.computeLuminance() > 0.45 ? _ink : Colors.white;

/// The cover art itself: [tagAccent], lit from the top left. Shared so a dead
/// url degrades to exactly what an imageless recipe already shows.
LinearGradient coverGradient(Color accent) => LinearGradient(
  begin: Alignment.topLeft,
  end: Alignment.bottomRight,
  colors: [
    accent,
    Color.alphaBlend(Colors.black.withValues(alpha: 0.22), accent),
  ],
);

/// The wash over a hero photo. Only at the very bottom, under the credit line:
/// the buttons at the top sit on frosted pills and need nothing from the
/// picture, which is the thing being looked at.
const heroScrim = LinearGradient(
  begin: Alignment.bottomCenter,
  end: Alignment.topCenter,
  colors: [Color(0x73000000), Color(0x00000000)],
  stops: [0, 0.35],
);

// ---------------------------------------------------------------------------
// Structure
// ---------------------------------------------------------------------------

/// A [Scaffold] on the plain page.
///
/// The body still sits behind the app bar, so screens written for the glass
/// look keep working: scrollable children add [glassAppBarInset] to their top
/// padding, and the bar is opaque now so nothing shows through.
class GlassScaffold extends StatelessWidget {
  final PreferredSizeWidget? appBar;
  final Widget? floatingActionButton;
  final FloatingActionButtonLocation? floatingActionButtonLocation;
  final Widget body;

  const GlassScaffold({
    super.key,
    this.appBar,
    this.floatingActionButton,
    this.floatingActionButtonLocation,
    required this.body,
  });

  @override
  Widget build(BuildContext context) => Scaffold(
    extendBodyBehindAppBar: true,
    appBar: appBar,
    floatingActionButton: floatingActionButton,
    floatingActionButtonLocation: floatingActionButtonLocation,
    body: body,
  );
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

/// Frosted glass, for the controls that float over the page and nothing else:
/// the bars content scrolls under, the buttons over the hero photo, the import
/// button, the photo sheet. That is where iOS puts Liquid Glass. The page, its
/// cards and its lists stay flat, as Spread drew them, because glass on content
/// is the thing Apple's guidance rules out.
///
/// The same on Android and iOS: a blur of what is behind, [tint] over it, a
/// light rim on the edge. [tint] needs some transparency or there is nothing
/// to see through it. [lift] is a soft shadow, for a control floating free
/// rather than one docked to an edge.
Widget frost({
  required BuildContext context,
  required ShapeBorder shape,
  required Color tint,
  required Widget child,
  bool lift = false,
}) {
  final rim = Colors.white.withValues(alpha: _isDark(context) ? 0.12 : 0.5);
  return DecoratedBox(
    decoration: ShapeDecoration(
      shape: shape,
      shadows: [
        if (lift)
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.16),
            blurRadius: 18,
            offset: const Offset(0, 6),
          ),
      ],
    ),
    child: ClipPath(
      clipper: ShapeBorderClipper(shape: shape),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
        child: DecoratedBox(
          position: DecorationPosition.foreground,
          decoration: ShapeDecoration(
            shape: shape is OutlinedBorder
                ? shape.copyWith(side: BorderSide(color: rim))
                : shape,
          ),
          child: ColoredBox(color: tint, child: child),
        ),
      ),
    ),
  );
}

/// How much of the page shows through a [frost] tint: enough that what
/// scrolls under it reads as shapes and colour, not enough to read words.
const frostAlpha = 0.72;

/// The bar's own surface: frosted page colour with a hairline under it.
///
/// [opacity] ramps it in, so the detail screen's photo can scroll up and
/// under it as the hero collapses. Deliberately not an animation: the hero
/// drives this straight off its own layout extent.
Widget barPane(BuildContext context, {double opacity = 1}) {
  final scheme = Theme.of(context).colorScheme;
  return ClipRect(
    child: BackdropFilter(
      filter: ImageFilter.blur(sigmaX: 20 * opacity, sigmaY: 20 * opacity),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: scheme.surface.withValues(alpha: frostAlpha * opacity),
          border: Border(
            bottom: BorderSide(
              color: glassRim(context).withValues(alpha: opacity),
            ),
          ),
        ),
        child: const SizedBox.expand(),
      ),
    ),
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
    flexibleSpace: barPane(context),
  );
}

/// A flat panel on the wash colour.
///
/// [edge] paints a colour strip down the left side. It is a child rather than
/// a [Border] because a [BoxDecoration] asserts on a non-uniform border
/// combined with a border radius.
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
    return Container(
      // Dismissible wraps its child in a loose Stack, so a panel inside one is
      // handed loose width and would shrink to its content. Fill the width we
      // are offered instead of measuring it.
      width: double.infinity,
      margin: margin,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: fill ?? glassFill(context),
        borderRadius: BorderRadius.circular(panelRadius),
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

/// A page with no app bar: a round back button, the page's name set large in
/// the serif, and [children] under it in one scrolling column. Every screen
/// but the recipe view and the editor is one of these.
class SpreadPage extends StatelessWidget {
  final String title;

  /// A line under the title saying what the page is about.
  final String? subtitle;
  final List<Widget> children;

  /// Pinned under the scrolling column, above the keyboard — for the one
  /// action a page exists to take.
  final Widget? bottom;

  const SpreadPage({
    super.key,
    required this.title,
    this.subtitle,
    required this.children,
    this.bottom,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AnnotatedRegion<SystemUiOverlayStyle>(
      // No app bar to set the status bar's icons, so say it here.
      value: theme.brightness == Brightness.dark
          ? SystemUiOverlayStyle.light
          : SystemUiOverlayStyle.dark,
      child: Scaffold(
        bottomNavigationBar: bottom == null
            ? null
            : SafeArea(
                child: Padding(
                  padding: EdgeInsets.fromLTRB(
                    16,
                    8,
                    16,
                    8 + MediaQuery.viewInsetsOf(context).bottom,
                  ),
                  child: bottom,
                ),
              ),
        body: SafeArea(
          bottom: false,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 40),
            children: [
              // Beside the title rather than above it, which buys a row of
              // content. Top-aligned, so a title that wraps keeps the button
              // on its first line instead of floating between two.
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const RoundBackButton(),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Padding(
                      // Centres the first line on the 48px button.
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(title, style: theme.textTheme.headlineLarge),
                    ),
                  ),
                ],
              ),
              if (subtitle case final subtitle?) ...[
                const SizedBox(height: 8),
                Text(
                  subtitle,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
              const SizedBox(height: 24),
              ...children,
            ],
          ),
        ),
      ),
    );
  }
}

/// Back, as a round button on the wash rather than a bare arrow, so it reads
/// as a control on a page that has no bar around it.
class RoundBackButton extends StatelessWidget {
  const RoundBackButton({super.key});

  @override
  Widget build(BuildContext context) => IconButton(
    onPressed: () => Navigator.maybePop(context),
    tooltip: MaterialLocalizations.of(context).backButtonTooltip,
    style: IconButton.styleFrom(
      backgroundColor: glassFill(context),
      fixedSize: const Size(48, 48),
    ),
    icon: const BackButtonIcon(),
  );
}

/// "APPEARANCE", "LAST MADE": a small herb label over a group.
class SectionLabel extends StatelessWidget {
  final String text;

  const SectionLabel(this.text, {super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Text(
      text.toUpperCase(),
      style: weighted(
        theme.textTheme.labelMedium,
        FontWeight.w600,
      )?.copyWith(color: theme.colorScheme.primary, letterSpacing: 1.2),
    );
  }
}

/// A row of mutually exclusive choices on one pill: the chosen one sits on a
/// white chip. Lighter than [SegmentedButton], whose outlined segments and
/// check marks are a different visual language from the rest of the page.
class Segmented<T> extends StatelessWidget {
  final List<(T, String)> options;
  final T selected;
  final ValueChanged<T> onChanged;

  /// Share the full width equally rather than hugging the labels.
  final bool expand;

  const Segmented({
    super.key,
    required this.options,
    required this.selected,
    required this.onChanged,
    this.expand = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final label = weighted(theme.textTheme.bodyMedium, FontWeight.w600);
    return DecoratedBox(
      decoration: ShapeDecoration(
        shape: const StadiumBorder(),
        color: glassFill(context),
      ),
      child: Padding(
        padding: const EdgeInsets.all(4),
        child: Row(
          mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
          children: [
            for (final (value, text) in options)
              _segment(
                expand: expand,
                child: Semantics(
                  selected: value == selected,
                  inMutuallyExclusiveGroup: true,
                  button: true,
                  child: Material(
                    shape: const StadiumBorder(),
                    color: value == selected
                        ? scheme.surface
                        : Colors.transparent,
                    elevation: value == selected ? 1 : 0,
                    shadowColor: Colors.black26,
                    child: InkWell(
                      customBorder: const StadiumBorder(),
                      onTap: () => onChanged(value),
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(minHeight: 40),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 14),
                          child: Center(
                            widthFactor: 1,
                            child: Text(
                              text,
                              style: label?.copyWith(
                                color: value == selected
                                    ? scheme.onSurface
                                    : scheme.onSurfaceVariant,
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
        ),
      ),
    );
  }

  static Widget _segment({required bool expand, required Widget child}) =>
      expand ? Expanded(child: child) : child;
}

// ---------------------------------------------------------------------------
// Themes
// ---------------------------------------------------------------------------

/// Names, section heads and numerals. Instrument Serif ships a single weight,
/// so size and the italic carry all the hierarchy.
TextStyle serif(double size, {double height = 1.05, bool italic = false}) =>
    TextStyle(
      fontFamily: 'InstrumentSerif',
      fontSize: size,
      height: height,
      fontWeight: FontWeight.w400,
      fontStyle: italic ? FontStyle.italic : FontStyle.normal,
      letterSpacing: size >= 30 ? -0.5 : 0,
    );

TextTheme _textTheme(TextTheme base) {
  // Every Material style onto Geist, with its weight set on the axis too.
  TextStyle? geist(TextStyle? style) => weighted(
    style?.copyWith(fontFamily: 'Geist'),
    style?.fontWeight ?? FontWeight.w400,
  );
  final sans = base.apply(fontFamily: 'Geist');
  return sans.copyWith(
    displayLarge: geist(sans.displayLarge),
    displayMedium: geist(sans.displayMedium),
    displaySmall: geist(sans.displaySmall),
    // A screen's own title — "Recipes", "History".
    headlineLarge: base.headlineLarge?.merge(serif(46, height: 1)),
    // The recipe's name.
    headlineMedium: base.headlineMedium?.merge(serif(44, height: 1)),
    // Section heads: "Mise en place", "Method", "Cook log".
    headlineSmall: base.headlineSmall?.merge(serif(32)),
    // App bar titles on the screens that still have one.
    titleLarge: base.titleLarge?.merge(serif(26)),
    titleMedium: weighted(sans.titleMedium, FontWeight.w600),
    titleSmall: weighted(sans.titleSmall, FontWeight.w600),
    bodyLarge: geist(sans.bodyLarge)?.copyWith(height: 1.5),
    bodyMedium: geist(sans.bodyMedium)?.copyWith(height: 1.45),
    bodySmall: geist(sans.bodySmall),
    labelLarge: weighted(sans.labelLarge, FontWeight.w600),
    labelMedium: geist(sans.labelMedium),
    labelSmall: geist(sans.labelSmall),
  );
}

ThemeData _theme(ColorScheme scheme) {
  final base = ThemeData(colorScheme: scheme);
  final text = _textTheme(base.textTheme);
  final dark = scheme.brightness == Brightness.dark;
  final wash = dark ? _nightWash : _wash;
  final rule = dark ? _nightRule : _rule;
  const stadium = StadiumBorder();

  return base.copyWith(
    textTheme: text,
    scaffoldBackgroundColor: scheme.surface,
    dividerTheme: DividerThemeData(color: rule, thickness: 1, space: 1),
    appBarTheme: AppBarTheme(
      backgroundColor: scheme.surface,
      surfaceTintColor: Colors.transparent,
      scrolledUnderElevation: 0,
      elevation: 0,
      foregroundColor: scheme.onSurface,
      titleTextStyle: text.titleLarge?.copyWith(color: scheme.onSurface),
    ),
    chipTheme: ChipThemeData(
      backgroundColor: wash,
      side: BorderSide.none,
      labelStyle: text.labelMedium?.copyWith(color: scheme.onSurfaceVariant),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: wash,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(pillRadius),
        borderSide: BorderSide.none,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(pillRadius),
        borderSide: BorderSide.none,
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(pillRadius),
        borderSide: BorderSide(color: scheme.primary, width: 2),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        shape: stadium,
        minimumSize: const Size(64, 48),
        textStyle: text.labelLarge,
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        shape: stadium,
        minimumSize: const Size(64, 44),
        side: BorderSide(color: scheme.primary),
        textStyle: text.labelLarge,
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(textStyle: text.labelLarge),
    ),
    floatingActionButtonTheme: FloatingActionButtonThemeData(
      backgroundColor: scheme.primary,
      foregroundColor: scheme.onPrimary,
      shape: stadium,
      extendedTextStyle: text.labelLarge?.copyWith(fontSize: 16),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: scheme.surface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
      titleTextStyle: text.headlineSmall?.copyWith(color: scheme.onSurface),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: scheme.surface,
      surfaceTintColor: Colors.transparent,
      showDragHandle: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
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

const _lightScheme = ColorScheme(
  brightness: Brightness.light,
  primary: _herb,
  onPrimary: Color(0xFFFFFFFF),
  primaryContainer: _herbWash,
  onPrimaryContainer: Color(0xFF173A22),
  secondary: _muted,
  onSecondary: Color(0xFFFFFFFF),
  secondaryContainer: _wash,
  onSecondaryContainer: _ink,
  error: Color(0xFFA8321F),
  onError: Color(0xFFFFFFFF),
  errorContainer: Color(0xFFFBEDEA),
  onErrorContainer: Color(0xFF4A2018),
  surface: _paper,
  onSurface: _ink,
  onSurfaceVariant: _muted,
  surfaceContainerLowest: _paper,
  surfaceContainerLow: Color(0xFFF9F9F7),
  surfaceContainer: _wash,
  surfaceContainerHigh: _wash,
  surfaceContainerHighest: Color(0xFFEEEDEA),
  outline: Color(0xFF8C8A85),
  outlineVariant: _rule,
);

const _darkScheme = ColorScheme(
  brightness: Brightness.dark,
  primary: _herbLight,
  onPrimary: Color(0xFF0F2416),
  primaryContainer: _herbNight,
  onPrimaryContainer: Color(0xFFCFE8D5),
  secondary: _moonMuted,
  onSecondary: _night,
  secondaryContainer: _nightWash,
  onSecondaryContainer: _moon,
  error: Color(0xFFF08A73),
  onError: Color(0xFF3B0A08),
  errorContainer: Color(0xFF4D1F1C),
  onErrorContainer: Color(0xFFFFDAD4),
  surface: _night,
  onSurface: _moon,
  onSurfaceVariant: _moonMuted,
  surfaceContainerLowest: _night,
  surfaceContainerLow: Color(0xFF171816),
  surfaceContainer: _nightWash,
  surfaceContainerHigh: _nightWash,
  surfaceContainerHighest: Color(0xFF282926),
  outline: Color(0xFF7D7B76),
  outlineVariant: _nightRule,
);

abstract final class AppTheme {
  static ThemeData get dark => _theme(_darkScheme);
  static ThemeData get light => _theme(_lightScheme);
}

/// The chosen theme. One notifier rather than an InheritedWidget: `main()`
/// listens, the settings screen writes, nothing in between needs to know. It is
/// seeded from `RecipeStore.themeName` at startup and written back on change.
final themeMode = ValueNotifier(ThemeMode.system);
