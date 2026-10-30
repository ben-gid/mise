import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mise/recipe/recipe_models.dart';
import 'package:mise/recipe/recipe_parser.dart';
import 'package:mise/recipe/recipe_scaling.dart';

void main() {
  final parser = RecipeParser(File(recipeSchemaAsset).readAsStringSync());
  final recipe = parser.parse(
    File('test/fixtures/valid/focaccia.json').readAsStringSync(),
  );

  test('formats amounts without trailing noise', () {
    expect(formatAmount(1.0), '1');
    expect(formatAmount(1.5), '1.5');
    expect(formatAmount(166.666), '166.67');
    expect(formatAmount(500), '500');
  });

  test('scales amounts by servings', () {
    final flour = recipe.ingredientById('0001')!;
    expect(amountLabel(flour, scaleFactor(recipe, 4)), '500 g'); // base
    expect(amountLabel(flour, scaleFactor(recipe, 6)), '750 g');
    expect(amountLabel(flour, scaleFactor(recipe, 2)), '250 g');
  });

  test('countable items render without a unit', () {
    final garlic = recipe.ingredientById('0005')!;
    expect(amountLabel(garlic, scaleFactor(recipe, 4)), '4');
    expect(amountLabel(garlic, scaleFactor(recipe, 8)), '8');
  });

  test('fl_oz renders readably', () {
    expect(unitLabel(Unit.flOz), 'fl oz');
    expect(unitLabel(Unit.g), 'g');
  });

  test('step content substitutes scaled ingredient references', () {
    final rendered = renderContent(recipe.steps[0], recipe, 1.5);

    expect(rendered, contains('750 g bread flour'));
    expect(rendered, contains('600 ml water'));
    expect(rendered, isNot(contains('{0001}')));
  });

  test('unknown reference is left as written', () {
    final step = RecipeStep(
      id: 's9',
      title: 'Broken',
      content: 'Add {9999} to the pan.',
      timerSeconds: null,
    );
    expect(renderContent(step, recipe, 1), 'Add {9999} to the pan.');
  });

  test('share text is scaled, human-readable and free of refs', () {
    final text = formatForSharing(recipe, 8); // 2x base

    expect(text, startsWith('Garlic Butter Focaccia'));
    expect(text, contains('Serves 8'));
    expect(text, contains('- 1000 g bread flour'));
    expect(text, contains('- 8 garlic cloves')); // countable, no unit
    expect(text, contains('2. Bulk proof (2 h)'));
    expect(text, contains('Whisk 1000 g bread flour'));
    // The headnote reads straight under the title, the way a cookbook sets
    // one — not labelled 'Notes' at the foot of the page.
    expect(
      text,
      startsWith('Garlic Butter Focaccia\n\nA slow-proofed focaccia'),
    );
    expect(text, contains('Source: claude-generated'));
    expect(text, isNot(contains('{')));
  });

  group('a recipe that makes loaves', () {
    final loaves = parser.parse(
      File('test/fixtures/valid/makes_loaves.json').readAsStringSync(),
    ); // 2 loaves, serves 4

    test('scales by the loaf, with the servings following', () {
      final flour = loaves.ingredientById('0001')!;
      expect(baseCount(loaves), 2);
      expect(amountLabel(flour, scaleFactor(loaves, 4)), '1000 g');
      expect(countLabel(loaves, 1), '1 loaf');
      expect(yieldLine(loaves, 3), 'Makes 3 loaves · serves 6');
    });

    test('says nothing about servings below one person', () {
      final cookies = Recipe.fromJson({
        ...loaves.toJson(),
        'makes': {'amount': 24, 'one': 'cookie', 'other': 'cookies'},
      });
      expect(yieldLine(cookies, 1), 'Makes 1 cookie');
    });

    test('a recipe without one counts servings as before', () {
      expect(countLabel(recipe, 1), '1 serving');
      expect(yieldLine(recipe, 4), 'Serves 4');
    });
  });

  test('step content splits into prose and scaled references', () {
    final step = RecipeStep(
      id: 's9',
      title: 'Mix',
      content: 'Whisk {0001} with {9999}.',
      timerSeconds: null,
    );
    expect(contentParts(step, recipe, 2), [
      (amount: null, text: 'Whisk '),
      (amount: '1000 g', text: 'bread flour'),
      (amount: null, text: ' with {9999}.'),
    ]);
  });

  test('formats timer durations', () {
    expect(formatDuration(45), '45 s');
    expect(formatDuration(1500), '25 min');
    expect(formatDuration(7200), '2 h');
    expect(formatDuration(5400), '1 h 30 min');
  });
}
