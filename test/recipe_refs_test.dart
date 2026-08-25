import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mise/recipe/recipe_models.dart';
import 'package:mise/recipe/recipe_refs.dart';

void main() {
  final validJson = File('test/fixtures/valid_recipe.json').readAsStringSync();
  final recipe = Recipe.fromJson(jsonDecode(validJson) as Map<String, dynamic>);
  final ingredients = recipe.ingredients;

  test('ids become names for editing and names become ids again', () {
    const stored = 'Whisk {0001}, {0003} and {0004}, then pour in {0002}.';
    const shown =
        'Whisk [bread flour], [fine sea salt] and [instant yeast], then '
        'pour in [water].';

    expect(toDisplayRefs(stored, ingredients), shown);
    expect(toIdRefs(shown, ingredients), stored);
  });

  test('every step in the fixture survives a round trip unchanged', () {
    for (final step in recipe.steps) {
      expect(
        toIdRefs(toDisplayRefs(step.content, ingredients), ingredients),
        step.content,
        reason: 'step ${step.id}',
      );
    }
  });

  test('a name that contains another name is not confused for it', () {
    // 'fine sea salt' and 'flaky salt' both end in salt — the brackets are
    // what keep them apart, and why a bare name would not work.
    const shown = 'Scatter [flaky salt] over the [fine sea salt] crust.';
    expect(
      toIdRefs(shown, ingredients),
      'Scatter {0007} over the {0003} crust.',
    );
  });

  test('an unknown id is left alone rather than rewritten', () {
    expect(toDisplayRefs('Add {9999}.', ingredients), 'Add {9999}.');
  });

  test('a mistyped bracket is reported instead of saved as prose', () {
    expect(unresolvedRefs('Melt [buter].', ingredients), ['buter']);
    expect(toIdRefs('Melt [buter].', ingredients), 'Melt [buter].');
    expect(unresolvedRefs('Melt [butter].', ingredients), isEmpty);
  });

  test('unused ingredients are the ones no step mentions', () {
    expect(unusedIngredients(recipe), isEmpty);

    final json = jsonDecode(validJson) as Map<String, dynamic>;
    (json['ingredients'] as List).add({
      'id': '0008',
      'name': 'olive oil',
      'amount': 2,
      'unit': 'tbsp',
    });
    expect(unusedIngredients(Recipe.fromJson(json)).map((i) => i.name), [
      'olive oil',
    ]);
  });

  group('two ingredients sharing a name', () {
    /// The fixture with a second butter — sugar for the sponge and sugar for
    /// the buttercream, which is why an LLM writes one name twice.
    List<Ingredient> twoButters() {
      final json = jsonDecode(validJson) as Map<String, dynamic>;
      (json['ingredients'] as List).add({
        'id': '0008',
        'name': 'butter',
        'amount': 20,
        'unit': 'g',
      });
      return Recipe.fromJson(json).ingredients;
    }

    test('each gets its id appended, and only those two', () {
      expect(labelsFor(twoButters()), [
        'bread flour',
        'water',
        'fine sea salt',
        'instant yeast',
        'garlic cloves',
        'butter #0006',
        'flaky salt',
        'butter #0008',
      ]);
    });

    test('round trip keeps them apart instead of collapsing onto one', () {
      final ingredients = twoButters();
      const stored = 'Melt {0006}. Later beat in {0008}.';
      const shown = 'Melt [butter #0006]. Later beat in [butter #0008].';

      expect(toDisplayRefs(stored, ingredients), shown);
      // The bug this labelling exists for: keyed by bare name, both of these
      // resolved to whichever butter came last, silently pointing the first
      // step at the wrong amount.
      expect(toIdRefs(shown, ingredients), stored);
    });

    test('a bare name is reported rather than resolved to a guess', () {
      final ingredients = twoButters();
      expect(unresolvedRefs('Melt [butter].', ingredients), ['butter']);
      expect(toIdRefs('Melt [butter].', ingredients), 'Melt [butter].');
    });

    test('everything else in the recipe still reads as its plain name', () {
      final ingredients = twoButters();
      expect(
        toDisplayRefs('Whisk {0001} into {0002}.', ingredients),
        'Whisk [bread flour] into [water].',
      );
      expect(unresolvedRefs('Whisk [bread flour].', ingredients), isEmpty);
    });
  });

  test('an unnamed ingredient has no label to be referred to by', () {
    // Only reachable as a half-typed editor draft — the schema requires a
    // name — but the editor offers labels as insert chips, and a blank one
    // would be an unusable chip.
    expect(
      labelsFor([
        const Ingredient(id: '0001', name: '', amount: 1, unit: Unit.g),
        const Ingredient(id: '0002', name: '  ', amount: 1, unit: Unit.g),
      ]),
      ['', ''],
    );
  });

  test('new ids fill the first free slot', () {
    expect(nextIngredientId(ingredients.map((i) => i.id)), '0008');
    expect(nextStepId(recipe.steps.map((s) => s.id)), 's5');

    // ...including a gap left by a removal, rather than counting past it.
    final gapped = [
      for (final i in ingredients)
        if (i.id != '0003') i,
    ];
    expect(nextIngredientId(gapped.map((i) => i.id)), '0003');
  });
}
