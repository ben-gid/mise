import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mise/recipe/recipe_models.dart';
import 'package:mise/recipe/recipe_refs.dart';

void main() {
  final validJson = File('test/fixtures/valid_recipe.json').readAsStringSync();
  final recipe = Recipe.fromJson(
    jsonDecode(validJson) as Map<String, dynamic>,
  );
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
    expect(toIdRefs(shown, ingredients), 'Scatter {0007} over the {0003} crust.');
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
    expect(
      unusedIngredients(Recipe.fromJson(json)).map((i) => i.name),
      ['olive oil'],
    );
  });

  test('duplicate names are caught, since a bracket could not choose', () {
    expect(duplicateNames(ingredients), isEmpty);

    final json = jsonDecode(validJson) as Map<String, dynamic>;
    (json['ingredients'] as List).add({
      'id': '0008',
      'name': 'butter',
      'amount': 20,
      'unit': 'g',
    });
    expect(duplicateNames(Recipe.fromJson(json).ingredients), ['butter']);
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
