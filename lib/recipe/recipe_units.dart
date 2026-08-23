import 'dart:math' show max, min;

import 'package:flutter/foundation.dart' show ValueNotifier;

import 'recipe_models.dart';

/// Which system amounts are *displayed* in. Storage is untouched — a recipe
/// stays in whatever unit it was imported with, and conversion happens at
/// render time, after scaling.
enum UnitSystem { metric, imperial }

/// Globals in the same shape as `themeMode`: the four callers of `amountLabel`
/// need no extra argument, and a test sets these directly.
final weightSystem = ValueNotifier(UnitSystem.metric);
final volumeSystem = ValueNotifier(UnitSystem.metric);

/// Which *dimension* amounts are displayed in, where an ingredient carries a
/// density and can be read either way. Orthogonal to the two systems above:
/// this picks grams-or-millilitres, those pick how each of them reads.
enum MeasureBy { asWritten, weight, volume }

final measureBy = ValueNotifier(MeasureBy.asWritten);

/// `1.0` -> "1", `166.666` -> "166.67".
String formatAmount(num amount) {
  final rounded = (amount * 100).round() / 100;
  return rounded == rounded.roundToDouble()
      ? rounded.round().toString()
      : rounded.toString();
}

String unitLabel(Unit unit) => switch (unit) {
  Unit.flOz => 'fl oz',
  _ => unit.name,
};

const _gPerOz = 28.3495;
const _gPerLb = 453.592;

/// Every unit with a fixed factor into the canonical gram or millilitre. The
/// import prompt asks the LLM for g and ml, but a hand-edited recipe can be
/// written in cups, and it still has to be readable in millilitres.
const _gramsPer = {
  Unit.g: 1.0,
  Unit.kg: 1000.0,
  Unit.oz: _gPerOz,
  Unit.lb: _gPerLb,
};
const _mlPer = {
  Unit.ml: 1.0,
  Unit.l: 1000.0,
  Unit.tsp: 4.92892,
  Unit.tbsp: 14.78676,
  Unit.cup: 236.5882,
  Unit.flOz: 29.5735,
};

/// Whether a unit lands in one of the two canonical values at all. `pinch` and
/// countable items don't, so no density can rescue them.
bool unitConverts(Unit? unit) =>
    unit != null && (_gramsPer.containsKey(unit) || _mlPer.containsKey(unit));

/// Whether this ingredient can be shown in the other dimension at all — which
/// is what decides if its amount offers a toggle.
bool canConvert(Ingredient i) =>
    i.densityGPerMl != null && unitConverts(i.unit);

/// Renders [amount] of [unit] in the user's chosen system, rounded to
/// measurements that exist in a kitchen ("¾ cup + 1½ tbsp").
///
/// The stored unit decides which dimension this *starts* in; [density] is what
/// lets it cross into the other one, and [flip] inverts the choice for a single
/// tapped ingredient. `pinch` has no factor either way, so it stays as written.
/// The dimension the recipe stored an amount in, and the one it will render
/// in: the global setting, with `asWritten` resolving to whatever was stored
/// and [flip] inverting it for a single tapped row.
///
/// Null when the unit lands in neither factor map — `pinch` and countable
/// items, which have no dimension to be in.
({MeasureBy stored, MeasureBy target})? _dimensions(Unit unit, bool flip) {
  final stored = _gramsPer.containsKey(unit)
      ? MeasureBy.weight
      : _mlPer.containsKey(unit)
      ? MeasureBy.volume
      : null;
  if (stored == null) return null;
  var target = switch (measureBy.value) {
    MeasureBy.asWritten => stored,
    final chosen => chosen,
  };
  if (flip) {
    target = target == MeasureBy.weight ? MeasureBy.volume : MeasureBy.weight;
  }
  return (stored: stored, target: target);
}

/// Whether this amount is computed through a density rather than read as the
/// recipe stored it — true whether the crossing came from a tapped row or from
/// the global setting. The row highlight is the only thing that says so, which
/// is why this and [formatMeasure] must resolve the dimension the same way:
/// both go through [_dimensions].
bool isDerived(Ingredient i, {bool flip = false}) {
  if (i.densityGPerMl == null || i.unit == null) return false;
  final dimensions = _dimensions(i.unit!, flip);
  return dimensions != null && dimensions.target != dimensions.stored;
}

String formatMeasure(num amount, Unit unit, {num? density, bool flip = false}) {
  final dimensions = _dimensions(unit, flip);
  // pinch, and anything else in neither factor map, reads as written.
  if (dimensions == null) return '${_metric(amount)} ${unitLabel(unit)}';

  var grams = _gramsPer[unit] == null ? null : amount * _gramsPer[unit]!;
  var ml = _mlPer[unit] == null ? null : amount * _mlPer[unit]!;

  // Density is the bridge between the two canonical values. Without one the
  // target is ignored and the ingredient reads as stored — the same silent
  // opt-out `pinch` already gets from the two factor maps.
  if (density != null && dimensions.target != dimensions.stored) {
    if (dimensions.target == MeasureBy.volume) {
      (ml, grams) = (grams! / density, null);
    } else {
      (grams, ml) = (ml! * density, null);
    }
  }

  return grams != null
      ? (weightSystem.value == UnitSystem.imperial
            ? _weight(grams)
            : '${_metric(grams)} g')
      : (volumeSystem.value == UnitSystem.imperial
            ? _volume(ml!)
            : '${_metricMl(ml!)} ml');
}

/// Whole numbers once an amount is big enough that a decimal is noise — a 1.33x
/// scale turns 500 into 666.67, and nobody weighs the 0.67.
String _metric(num value) =>
    value >= 10 ? value.round().toString() : formatAmount(value);

/// Millilitres round harder than grams do: a millilitre is already a fifth of a
/// teaspoon, so a converted tsp reads as "5 ml" rather than "4.93 ml". Grams
/// keep their decimals, where 2.5 g of yeast really is not 3 g.
String _metricMl(num value) =>
    value >= 1 ? value.round().toString() : formatAmount(value);

/// Weight reads in decimals rather than the fractions volume uses, because it
/// is measured on a scale: "1 lb 9.1 oz", never "1 lb 9⅛ oz".
///
/// Above a pound it takes two terms, matching the `lb:oz` mode every scale with
/// an imperial setting has — budget scales cycle `g / lb:oz / fl.oz / ml` and
/// offer no ounces-only mode at all, and none of them can show decimal pounds,
/// so "1.57 lb" is a number nobody can dial in.
String _weight(num grams) {
  // ponytail: below ~½ oz nothing imperial reads well — a scale's tenth of an
  // ounce is 13% of 5 g. Grams are more accurate *and* what US recipes print
  // for salt and yeast.
  if (grams < 14) return '${_metric(grams)} g';
  // Tenth-ounces throughout: it is exactly what a lb:oz display resolves, and
  // one rounding means the remainder can never round up into a 16th ounce.
  // It also keeps 453.5 g off a "16 oz" that should read as a pound.
  final tenthOunces = (grams / _gPerOz * 10).round();
  if (tenthOunces < 160) return '${formatAmount(tenthOunces / 10)} oz';
  final pounds = tenthOunces ~/ 160;
  final remainder = tenthOunces % 160;
  return remainder == 0
      ? '$pounds lb'
      : '$pounds lb ${formatAmount(remainder / 10)} oz';
}

/// Volume works in integer quarter-teaspoons: tsp = 4, tbsp = 12, cup = 192.
/// Integers mean no float edges and no double-rounding when a two-term
/// expression splits across units.
const _mlPerQuarterTsp = 4.92892 / 4;

/// Within this of a single rung, one term wins. Wider and 200 ml would read as
/// "¾ cup" — 11% short, which is a different loaf of bread.
const _singleTermTolerance = 0.02;

String _volume(num ml) {
  final q = (ml / _mlPerQuarterTsp).round();
  if (q == 0) return '${_metricMl(ml)} ml'; // under an eighth of a teaspoon
  final rungs = _rungs(q);

  final nearest = rungs.reduce(
    (a, b) => (a - q).abs() <= (b - q).abs() ? a : b,
  );
  if ((nearest - q).abs() <= q * _singleTermTolerance) return _label(nearest);

  // Two terms: floor onto the ladder, spend the remainder one step down.
  final primary = rungs.where((r) => r <= q).reduce(max);
  final rem = q - primary;
  // Quarter-teaspoons express any remainder exactly, but "8¾ tsp" is not how a
  // recipe reads. Take the half-tablespoon when it costs less than the same
  // tolerance a single term gets, and stay exact when it doesn't.
  final tbsp = (rem / 6).round() * 6;
  final secondary = tbsp >= 12 && (tbsp - rem).abs() <= q * _singleTermTolerance
      ? tbsp
      : rem;
  // A second term worth under 2.5% of the first is noise — nobody adds ¼ tsp
  // of water to a cup. Below ~3 tbsp that same ¼ tsp does matter, which is why
  // the floor is relative and not a fixed amount.
  if (secondary * 40 < primary) return _label(primary);

  // Rounding the remainder up can land on the next rung, and "¾ cup + 4 tbsp"
  // should just say "1 cup".
  final next = rungs.where((r) => r > primary).reduce(min);
  if (primary + secondary >= next) return _label(next);

  return '${_label(primary)} + ${_label(secondary)}';
}

/// Every single-term measurement worth showing, in quarter-teaspoons: every
/// ¼ tsp up to 3 tsp, every ½ tbsp up to a ¼ cup, then cups in the fractions a
/// measuring set actually has.
List<int> _rungs(int q) => [
  for (var i = 1; i <= 11; i++) i,
  for (var i = 12; i < 48; i += 6) i,
  for (var cups = 0; cups <= q ~/ 192 + 1; cups++)
    for (final frac in const [0, 48, 64, 96, 128, 144])
      if (cups > 0 || frac > 0) cups * 192 + frac,
];

String _label(int q) {
  if (q >= 48) return '${_mixed(q, 192)} cup${q > 192 ? 's' : ''}';
  // Tablespoons only when they land exactly — a half tablespoon is 1½ tsp, so
  // anything off that grid reads truer as teaspoons.
  if (q >= 12 && q % 6 == 0) return '${_mixed(q, 12)} tbsp';
  return '${_mixed(q, 4)} tsp';
}

/// Only volume uses fractions, and its ladders reduce to these five.
const _glyphs = {'1/4': '¼', '1/3': '⅓', '1/2': '½', '2/3': '⅔', '3/4': '¾'};

/// `144/192` -> "¾". Reduced first, so 64/192 comes out as ⅓ rather than a
/// fraction nobody has a cup for.
String _mixed(int count, int denominator) {
  final whole = count ~/ denominator;
  var numerator = count % denominator;
  if (numerator == 0) return '$whole';
  var den = denominator;
  final divisor = _gcd(numerator, den);
  numerator ~/= divisor;
  den ~/= divisor;
  final glyph = _glyphs['$numerator/$den'] ?? '$numerator/$den';
  return whole == 0 ? glyph : '$whole$glyph';
}

int _gcd(int a, int b) => b == 0 ? a : _gcd(b, a % b);
