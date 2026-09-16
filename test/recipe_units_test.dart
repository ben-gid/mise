import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mise/recipe/recipe_models.dart';
import 'package:mise/recipe/recipe_parser.dart';
import 'package:mise/recipe/recipe_scaling.dart';
import 'package:mise/recipe/recipe_store.dart';
import 'package:mise/recipe/recipe_units.dart';

void main() {
  setUp(() {
    weightSystem.value = UnitSystem.imperial;
    volumeSystem.value = UnitSystem.imperial;
    measureBy.value = MeasureBy.asWritten;
  });
  tearDown(() {
    weightSystem.value = UnitSystem.metric;
    volumeSystem.value = UnitSystem.metric;
    measureBy.value = MeasureBy.asWritten;
  });

  test('metric leaves g and ml alone, without decimal noise', () {
    weightSystem.value = UnitSystem.metric;
    volumeSystem.value = UnitSystem.metric;

    expect(formatMeasure(500, Unit.g), '500 g');
    expect(formatMeasure(1000, Unit.g), '1000 g');
    expect(formatMeasure(666.666, Unit.g), '667 g'); // 500 g at 1.33x
    expect(formatMeasure(1.5, Unit.ml), '2 ml'); // ml round to whole ml
    expect(formatMeasure(0.5, Unit.ml), '0.5 ml'); // until below one
  });

  test('imperial volume snaps to one term when it is close enough', () {
    expect(formatMeasure(236.588, Unit.ml), '1 cup'); // exact
    expect(formatMeasure(235, Unit.ml), '1 cup'); // 0.7% — inside tolerance
    expect(formatMeasure(78.9, Unit.ml), '⅓ cup');
    expect(formatMeasure(60, Unit.ml), '¼ cup'); // trailing ¼ tsp is noise
    expect(formatMeasure(15, Unit.ml), '1 tbsp');
    expect(formatMeasure(30, Unit.ml), '2 tbsp');
    expect(formatMeasure(5, Unit.ml), '1 tsp');
    expect(formatMeasure(600, Unit.ml), '2½ cups');
  });

  test('imperial volume spends the remainder on a second term', () {
    // Nearest single rung is ¾ cup, 11% short — a different loaf of bread.
    expect(formatMeasure(200, Unit.ml), '¾ cup + 1½ tbsp');
    expect(formatMeasure(100, Unit.ml), '⅓ cup + 1½ tbsp');
    expect(formatMeasure(250, Unit.ml), '1 cup + 1 tbsp');
    expect(formatMeasure(500, Unit.ml), '2 cups + 2 tbsp');
    // Quarter-teaspoons when a half tablespoon would cost more than the
    // tolerance a single term gets.
    expect(formatMeasure(90, Unit.ml), '⅓ cup + 2¼ tsp');
  });

  // 3.5% is what the rules actually guarantee, and the worst case sits at the
  // ¼ cup rung: a single term snaps within 2%, dropping a noise-floor second
  // term gives back up to 2.4% more, and quantising to ¼ tsp adds ~1% at that
  // size. In millilitres the worst case is under 2 ml.
  test('imperial volume stays within 3.5% from a quarter cup up', () {
    for (var ml = 59.0; ml < 2000; ml *= 1.003) {
      expect(
        _remeasure(formatMeasure(ml, Unit.ml)),
        closeTo(ml, ml * 0.035),
        reason: '$ml ml rendered as "${formatMeasure(ml, Unit.ml)}"',
      );
    }
  });

  // Weight is read off a scale, so it stays decimal — the fractions belong to
  // measuring cups and spoons, not to a display that shows 1.5. Above a pound
  // it takes two terms, the way a scale's lb:oz mode reads: no scale can show
  // a decimal pound, so "1.57 lb" would be undialable.
  test('imperial weight is decimal ounces, then pounds and ounces', () {
    expect(formatMeasure(28.35, Unit.g), '1 oz');
    expect(formatMeasure(60, Unit.g), '2.1 oz');
    expect(formatMeasure(113, Unit.g), '4 oz');
    expect(formatMeasure(250, Unit.g), '8.8 oz');
    expect(formatMeasure(500, Unit.g), '1 lb 1.6 oz');
    expect(formatMeasure(712, Unit.g), '1 lb 9.1 oz');
    expect(formatMeasure(750, Unit.g), '1 lb 10.5 oz');
    expect(formatMeasure(1000, Unit.g), '2 lb 3.3 oz');
  });

  test('a whole number of pounds drops the ounce term', () {
    expect(formatMeasure(907.18, Unit.g), '2 lb');
    expect(formatMeasure(2268, Unit.g), '5 lb');
  });

  test('a hair under a pound reads as a pound, not 16 oz', () {
    expect(formatMeasure(453.5, Unit.g), '1 lb');
    expect(formatMeasure(450, Unit.g), '15.9 oz');
  });

  test('imperial weight keeps grams below half an ounce', () {
    // A scale's tenth of an ounce is 13% of 5 g. Grams are more accurate and
    // what US recipes print for salt and yeast anyway.
    expect(formatMeasure(10, Unit.g), '10 g');
    expect(formatMeasure(5, Unit.g), '5 g');
    expect(formatMeasure(14, Unit.g), '0.5 oz');
  });

  // The stored unit only says which dimension an amount is; the setting says
  // how it reads. A recipe hand-written in cups is still readable in metric.
  test('units the prompt never asks for still convert', () {
    weightSystem.value = UnitSystem.metric;
    volumeSystem.value = UnitSystem.metric;

    expect(formatMeasure(2, Unit.cup), '473 ml');
    expect(formatMeasure(3, Unit.tbsp), '44 ml');
    expect(formatMeasure(1, Unit.tsp), '5 ml');
    expect(formatMeasure(8, Unit.flOz), '237 ml');
    expect(formatMeasure(1, Unit.l), '1000 ml');
    expect(formatMeasure(4, Unit.oz), '113 g');
    expect(formatMeasure(1, Unit.lb), '454 g');
    expect(formatMeasure(1, Unit.kg), '1000 g');
  });

  test('a US-written recipe round-trips back to what it said', () {
    expect(formatMeasure(2, Unit.cup), '2 cups');
    expect(formatMeasure(3, Unit.tbsp), '3 tbsp');
    expect(formatMeasure(1, Unit.tsp), '1 tsp');
    expect(formatMeasure(4, Unit.oz), '4 oz');
    expect(formatMeasure(1, Unit.lb), '1 lb');
  });

  test('pinch has no factor, so it reads as written either way', () {
    expect(formatMeasure(1, Unit.pinch), '1 pinch');
    volumeSystem.value = UnitSystem.metric;
    expect(formatMeasure(1, Unit.pinch), '1 pinch');
  });

  // The whole point of the setting, end to end: a recipe saved the way a US
  // cook writes it has to be readable by someone who measures in millilitres.
  test('a recipe saved in US units renders in metric', () async {
    final dir = Directory.systemTemp.createTempSync('recipe_units_test');
    addTearDown(() => dir.deleteSync(recursive: true));
    final store = RecipeStore(dir);
    final parser = RecipeParser(File(recipeSchemaAsset).readAsStringSync());

    final json =
        jsonDecode(File('test/fixtures/valid_recipe.json').readAsStringSync())
            as Map<String, dynamic>;
    json['ingredients'] = [
      {'id': '0001', 'name': 'milk', 'amount': 2, 'unit': 'cup'},
      {'id': '0002', 'name': 'flour', 'amount': 1, 'unit': 'lb'},
    ];
    json['steps'] = [
      {
        'id': 's1',
        'title': 'Mix',
        'content': 'Whisk {0001} into {0002}.',
        'timer_seconds': null,
      },
    ];
    final id = await store.save(parser.parse(jsonEncode(json)));
    final recipe = (await store.loadAll()).firstWhere((r) => r.$1 == id).$2;

    weightSystem.value = UnitSystem.metric;
    volumeSystem.value = UnitSystem.metric;
    expect(amountLabel(recipe.ingredients[0], 1), '473 ml');
    expect(amountLabel(recipe.ingredients[1], 1), '454 g');
    expect(
      renderContent(recipe.steps.first, recipe, 1),
      'Whisk 473 ml milk into 454 g flour.',
    );

    // And back, unchanged from what the recipe actually said.
    weightSystem.value = UnitSystem.imperial;
    volumeSystem.value = UnitSystem.imperial;
    expect(amountLabel(recipe.ingredients[0], 1), '2 cups');
    expect(amountLabel(recipe.ingredients[1], 1), '1 lb');
  });

  // -------------------------------------------------------------- density

  group('density bridges the two dimensions', () {
    // The canonical case: weighed on a scale, wanted in cups.
    test('grams read as volume when the ingredient carries a density', () {
      volumeSystem.value = UnitSystem.imperial;
      measureBy.value = MeasureBy.volume;
      expect(formatMeasure(500, Unit.g, density: 0.53), '4 cups');
    });

    // The more valuable direction: a recipe written in cups becomes weighable,
    // which is what makes scaling it honest.
    test('volume reads as grams', () {
      weightSystem.value = UnitSystem.metric;
      measureBy.value = MeasureBy.weight;
      expect(formatMeasure(2, Unit.cup, density: 1.0), '473 g');
    });

    // The guard on every other expectation in this file: a density in the
    // recipe changes nothing until a reader asks for the other dimension.
    test('a density alone changes nothing under asWritten', () {
      weightSystem.value = UnitSystem.metric;
      volumeSystem.value = UnitSystem.metric;
      expect(formatMeasure(500, Unit.g, density: 0.53), '500 g');
      expect(formatMeasure(2, Unit.cup, density: 1.0), '473 ml');
    });

    test('without a density the setting is ignored rather than guessed at', () {
      weightSystem.value = UnitSystem.metric;
      measureBy.value = MeasureBy.volume;
      expect(formatMeasure(500, Unit.g), '500 g');
    });

    test('pinch stays as written under every dimension', () {
      for (final by in MeasureBy.values) {
        measureBy.value = by;
        expect(formatMeasure(1, Unit.pinch, density: 0.5), '1 pinch');
      }
    });

    // The row highlight is the only thing that says "computed, not measured",
    // so this predicate has to agree with what formatMeasure actually did.
    test('isDerived marks exactly the values that crossed a dimension', () {
      const water = Ingredient(
        id: '0002',
        name: 'water',
        amount: 200,
        unit: Unit.ml,
        densityGPerMl: 1.0,
      );
      const eggs = Ingredient(id: '0005', name: 'eggs', amount: 2);

      measureBy.value = MeasureBy.asWritten;
      expect(isDerived(_flour), isFalse);
      expect(isDerived(water), isFalse);
      // A tap crosses it even when the setting hasn't.
      expect(isDerived(_flour, flip: true), isTrue);

      measureBy.value = MeasureBy.volume;
      expect(isDerived(_flour), isTrue); // grams -> cups, computed
      expect(isDerived(water), isFalse); // already volume, just relabelled
      // Tapping a derived row back onto its stored unit is no longer derived.
      expect(isDerived(_flour, flip: true), isFalse);

      // No density, and nothing with a dimension to cross.
      expect(isDerived(eggs), isFalse);
      expect(
        isDerived(
          const Ingredient(
            id: '1',
            name: 'salt',
            amount: 1,
            unit: Unit.pinch,
            densityGPerMl: 1.2,
          ),
        ),
        isFalse,
      );
    });

    test('flip inverts one ingredient against the global setting', () {
      weightSystem.value = UnitSystem.metric;
      volumeSystem.value = UnitSystem.metric;
      expect(formatMeasure(500, Unit.g, density: 0.53), '500 g');
      expect(formatMeasure(500, Unit.g, density: 0.53, flip: true), '943 ml');
      // Flipping against a global that already asked for volume lands back on
      // what the recipe actually says.
      measureBy.value = MeasureBy.volume;
      expect(formatMeasure(500, Unit.g, density: 0.53, flip: true), '500 g');
    });

    test('canConvert is false for anything with no fixed factor', () {
      expect(canConvert(_flour), isTrue);
      expect(
        canConvert(
          const Ingredient(id: '2', name: 'flour', amount: 500, unit: Unit.g),
        ),
        isFalse,
      );
      expect(
        canConvert(
          const Ingredient(
            id: '3',
            name: 'eggs',
            amount: 2,
            densityGPerMl: 1.0,
          ),
        ),
        isFalse,
      );
      expect(
        canConvert(
          const Ingredient(
            id: '4',
            name: 'salt',
            amount: 1,
            unit: Unit.pinch,
            densityGPerMl: 1.2,
          ),
        ),
        isFalse,
      );
    });

    // Steps carry no control of their own, so the inline refs have to follow
    // whatever the ingredient row was tapped into.
    test('a flipped ingredient changes the step text too', () {
      weightSystem.value = UnitSystem.metric;
      volumeSystem.value = UnitSystem.metric;
      final recipe = Recipe(
        title: 'Loaf',
        baseServings: 1,
        ingredients: const [_flour],
        steps: const [
          RecipeStep(id: 's1', title: 'Mix', content: 'Add {0001}.'),
        ],
        tags: const [],
        source: 'test',
        createdAt: DateTime(2024),
      );
      final step = recipe.steps.first;
      expect(renderContent(step, recipe, 1), 'Add 500 g flour.');
      expect(
        renderContent(step, recipe, 1, flipped: const {'0001'}),
        'Add 943 ml flour.',
      );
      // And the share text shows the same numbers the screen does.
      expect(
        formatForSharing(recipe, 1, flipped: const {'0001'}),
        contains('- 943 ml flour'),
      );
    });
  });
}

const _flour = Ingredient(
  id: '0001',
  name: 'flour',
  amount: 500,
  unit: Unit.g,
  densityGPerMl: 0.53,
);

/// Reads a rendered measurement back into millilitres, so a broken ladder rung
/// fails the tolerance check instead of quietly shipping.
double _remeasure(String label) => label
    .split(' + ')
    .map((term) {
      final parts = term.split(' ');
      final ml = switch (parts.last) {
        'cup' || 'cups' => 236.5882,
        'tbsp' => 14.78676,
        'tsp' => 4.92892,
        final other => fail('unexpected unit "$other" in "$label"'),
      };
      return _value(parts.first) * ml;
    })
    .reduce((a, b) => a + b);

const _fractions = {
  '⅛': 0.125,
  '¼': 0.25,
  '⅓': 1 / 3,
  '⅜': 0.375,
  '½': 0.5,
  '⅝': 0.625,
  '⅔': 2 / 3,
  '¾': 0.75,
  '⅞': 0.875,
};

/// "1½" -> 1.5, "¾" -> 0.75, "2" -> 2. Every glyph is a single code unit.
double _value(String text) {
  final fraction = _fractions[text[text.length - 1]];
  if (fraction == null) return double.parse(text);
  final whole = text.substring(0, text.length - 1);
  return (whole.isEmpty ? 0 : double.parse(whole)) + fraction;
}
