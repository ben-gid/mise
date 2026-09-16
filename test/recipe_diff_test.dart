import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mise/recipe/recipe_diff.dart';
import 'package:mise/recipe/recipe_models.dart';

/// Pure functions over two [Recipe]s — no store, no widgets, so this is a plain
/// `test()` file with none of the fake-async constraints widget_test.dart has.
void main() {
  final validJson = File('test/fixtures/valid_recipe.json').readAsStringSync();
  const headnote =
      'A slow-proofed focaccia with a garlic butter crust. The long cold '
      'rest is what gives it the open crumb \u2014 the dough can sit '
      'overnight in the fridge instead of the 2h bulk proof, and is easier '
      'to dimple cold.';

  Recipe original() =>
      Recipe.fromJson(jsonDecode(validJson) as Map<String, dynamic>);

  /// The fixture with [edit] applied to its decoded JSON.
  Recipe edited(void Function(Map<String, dynamic> json) edit) {
    final json = jsonDecode(validJson) as Map<String, dynamic>;
    edit(json);
    return Recipe.fromJson(json);
  }

  test('an unchanged recipe has no changes', () {
    expect(diffRecipes(original(), original()), isEmpty);
  });

  test('a changed amount is one line, in recipe units', () {
    final after = edited((json) {
      (json['ingredients'] as List)[5]['amount'] = 120; // butter, was 60 g
    });

    expect(diffRecipes(original(), after), [
      (
        kind: ChangeKind.ingredient,
        label: 'Ingredient',
        detail: 'amount',
        before: '60 g butter',
        after: '120 g butter',
      ),
    ]);
  });

  test('changing an amount does not also flag the steps that reference it', () {
    // The point of {0001} refs: the step text never repeats the amount, so it
    // is untouched by a rescale.
    final after = edited((json) {
      (json['ingredients'] as List)[0]['amount'] = 1000;
    });

    expect(
      diffRecipes(original(), after).where((c) => c.kind == ChangeKind.step),
      isEmpty,
    );
  });

  test('a renamed ingredient reads as a change, not add plus remove', () {
    final after = edited((json) {
      (json['ingredients'] as List)[1]['name'] = 'sparkling water';
    });

    expect(diffRecipes(original(), after), [
      (
        kind: ChangeKind.ingredient,
        label: 'Ingredient',
        detail: 'name',
        before: '400 ml water',
        after: '400 ml sparkling water',
      ),
    ]);
  });

  test('a change names every part of the ingredient that moved', () {
    final after = edited((json) {
      (json['ingredients'] as List)[5]
        ..['name'] = 'salted butter'
        ..['amount'] = 2
        ..['unit'] = 'tbsp';
    });

    // The diff renders through amountLabel, so amounts follow the unit
    // settings like everywhere else: 2 tbsp reads as 30 ml under metric.
    expect(diffRecipes(original(), after).single, (
      kind: ChangeKind.ingredient,
      label: 'Ingredient',
      detail: 'name, amount, unit',
      before: '60 g butter',
      after: '30 ml salted butter',
    ));
  });

  test('an added and a removed ingredient', () {
    final added = edited((json) {
      (json['ingredients'] as List).add({
        'id': '0008',
        'name': 'olive oil',
        'amount': 2,
        'unit': 'tbsp',
      });
    });
    expect(diffRecipes(original(), added), [
      (
        kind: ChangeKind.ingredient,
        label: 'Ingredient',
        detail: null,
        before: null,
        after: '30 ml olive oil',
      ),
    ]);

    // Removing 0007 also drops the step that referenced it, so compare the
    // other direction on the same pair instead of building a dangling recipe.
    expect(diffRecipes(added, original()), [
      (
        kind: ChangeKind.ingredient,
        label: 'Ingredient',
        detail: null,
        before: '30 ml olive oil',
        after: null,
      ),
    ]);
  });

  test('step content, title and timer each report separately', () {
    final after = edited((json) {
      (json['steps'] as List)[1]['title'] = 'Cold proof';
      (json['steps'] as List)[1]['timer_seconds'] = 43200;
    });

    expect(diffRecipes(original(), after), [
      (
        kind: ChangeKind.step,
        label: 'Step 2',
        detail: 'title',
        before: 'Bulk proof',
        after: 'Cold proof',
      ),
      (
        kind: ChangeKind.step,
        label: 'Step 2',
        detail: 'timer',
        before: '2 h',
        after: '12 h',
      ),
    ]);
  });

  test('a changed step reads with ingredient names, not ids', () {
    final after = edited((json) {
      (json['steps'] as List)[0]['content'] = 'Whisk {0001} and {0003} only.';
    });

    expect(diffRecipes(original(), after), [
      (
        kind: ChangeKind.step,
        label: 'Step 1',
        detail: 'wording',
        before:
            'Whisk [bread flour], [fine sea salt] and [instant yeast], '
            'then pour in [water] and mix to a shaggy dough.',
        after: 'Whisk [bread flour] and [fine sea salt] only.',
      ),
    ]);
  });

  test('each side of a step diff uses its own version of the names', () {
    final after = edited((json) {
      (json['ingredients'] as List)[0]['name'] = 'strong white flour';
      (json['steps'] as List)[0]['content'] = 'Sift {0001}.';
    });

    final step = diffRecipes(
      original(),
      after,
    ).firstWhere((change) => change.detail == 'wording');
    expect(step.before, contains('[bread flour]'));
    expect(step.after, 'Sift [strong white flour].');
  });

  test('a timer that was never set reads as added', () {
    final after = edited((json) {
      (json['steps'] as List)[0]['timer_seconds'] = 600;
    });

    expect(diffRecipes(original(), after), [
      (
        kind: ChangeKind.step,
        label: 'Step 1',
        detail: 'timer',
        before: null,
        after: '10 min',
      ),
    ]);
  });

  test('reordered steps are reported once, not per step', () {
    final after = edited((json) {
      final steps = json['steps'] as List;
      steps.insert(0, steps.removeAt(2)); // garlic butter first
    });

    expect(diffRecipes(original(), after), [
      (
        kind: ChangeKind.order,
        label: 'Step order',
        detail: null,
        before: null,
        after: null,
      ),
    ]);
  });

  test('tags are compared as a set, so reordering them is not a change', () {
    final reordered = edited((json) {
      json['tags'] = ['vegetarian', 'make-ahead', 'bread'];
    });
    expect(diffRecipes(original(), reordered), isEmpty);

    final swapped = edited((json) {
      json['tags'] = ['bread', 'vegetarian', 'weeknight'];
    });
    expect(diffRecipes(original(), swapped), [
      (
        kind: ChangeKind.tag,
        label: 'Tag',
        detail: null,
        before: null,
        after: 'weeknight',
      ),
      (
        kind: ChangeKind.tag,
        label: 'Tag',
        detail: null,
        before: 'make-ahead',
        after: null,
      ),
    ]);
  });

  test('scalar fields, with an emptied one reading as removed', () {
    final after = edited((json) {
      json['title'] = 'Rosemary Focaccia';
      json['base_servings'] = 8;
      json['notes'] = null;
    });

    expect(diffRecipes(original(), after), [
      (
        kind: ChangeKind.title,
        label: 'Title',
        detail: null,
        before: 'Garlic Butter Focaccia',
        after: 'Rosemary Focaccia',
      ),
      (
        kind: ChangeKind.notes,
        label: 'Notes',
        detail: null,
        before: headnote,
        after: null,
      ),
      (
        kind: ChangeKind.servings,
        label: 'Servings',
        detail: null,
        before: '4',
        after: '8',
      ),
    ]);
  });

  test('a photo arriving is a change, not a silent one', () {
    final after = edited(
      (json) => json['image_urls'] = ['https://example.com/new.jpg'],
    );

    expect(diffRecipes(original(), after), [
      (
        kind: ChangeKind.image,
        label: 'Images',
        detail: null,
        before: null, // the fixture carries no photos
        after: 'https://example.com/new.jpg',
      ),
    ]);
  });

  test(
    'reordering the photos is a change — the first one is the one shown',
    () {
      const a = 'https://a.example/1.jpg';
      const b = 'https://b.example/2.jpg';
      final before = edited((json) => json['image_urls'] = [a, b]);
      final after = edited((json) => json['image_urls'] = [b, a]);

      // Set-diffed like tags this would read as no change at all, and the
      // recipe would silently be showing a different picture.
      expect(diffRecipes(before, after), [
        (
          kind: ChangeKind.image,
          label: 'Images',
          detail: null,
          before: '$a\n$b',
          after: '$b\n$a',
        ),
      ]);
    },
  );
}
