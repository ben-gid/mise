import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mise/recipe/recipe_models.dart';
import 'package:mise/recipe/recipe_parser.dart';

void main() {
  final parser = RecipeParser(File(recipeSchemaAsset).readAsStringSync());
  final validJson = File('test/fixtures/valid_recipe.json').readAsStringSync();

  /// Invalid fixtures are the valid one with a single mutation applied, so each
  /// test pins exactly one failure.
  String mutated(void Function(Map<String, dynamic> r) mutate) {
    final map = jsonDecode(validJson) as Map<String, dynamic>;
    mutate(map);
    return jsonEncode(map);
  }

  List<String> errorsOf(String json) {
    try {
      parser.parse(json);
      fail('expected validation to fail');
    } on RecipeValidationException catch (e) {
      return e.errors;
    }
  }

  test('valid recipe parses cleanly', () {
    final recipe = parser.parse(validJson);

    expect(recipe.title, 'Garlic Butter Focaccia');
    expect(recipe.baseServings, 4);
    expect(recipe.createdAt, DateTime.utc(2026, 8, 13, 10, 24));
    expect(recipe.ingredients, hasLength(7));
    expect(recipe.ingredientById('0001')!.unit, Unit.g);
    expect(recipe.ingredientById('0005')!.unit, isNull); // countable item
    expect(recipe.steps[1].timerSeconds, 7200);
    expect(recipe.steps[0].timerSeconds, isNull);
    expect(recipe.tags, contains('bread'));
  });

  test('round-trips through toJson', () {
    // created_at is re-emitted in canonical ISO form, so compare the reparse
    // rather than the raw strings.
    final round = parser.parse(jsonEncode(parser.parse(validJson).toJson()));
    expect(round.toJson(), parser.parse(validJson).toJson());
    expect(round.ingredientById('0005')!.unit, isNull);
    expect(round.steps.map((s) => s.timerSeconds), [null, 7200, 300, 1500]);
  });

  test('missing required field fails', () {
    final errors = errorsOf(mutated((r) => r.remove('base_servings')));
    expect(errors.first, contains('base_servings'));
    expect(errors.first, contains('required'));
  });

  test('bad unit enum value fails', () {
    final errors = errorsOf(
      mutated((r) => (r['ingredients'] as List)[0]['unit'] = 'grams'),
    );
    expect(errors.single, contains('/ingredients/0/unit'));
    expect(errors.single, contains('enum'));
  });

  test('wrong type fails', () {
    final errors = errorsOf(mutated((r) => r['base_servings'] = '4'));
    expect(errors.single, contains('base_servings'));
    expect(errors.single, contains('integer'));
  });

  test('malformed ingredient id fails the 4-char pattern', () {
    final errors = errorsOf(
      mutated((r) => (r['ingredients'] as List)[0]['id'] = '1'),
    );
    expect(errors, isNotEmpty);
    expect(errors.first, contains('pattern'));
  });

  test('unknown key is rejected', () {
    final errors = errorsOf(mutated((r) => r['calories'] = 900));
    expect(errors.single, contains('calories'));
  });

  test('step referencing an unknown ingredient id fails', () {
    final errors = errorsOf(
      mutated((r) => (r['steps'] as List)[0]['content'] = 'Mix {9999}.'),
    );
    expect(errors.single, contains('unknown ingredient id {9999}'));
  });

  test('malformed JSON fails without crashing', () {
    final errors = errorsOf('{"title": ');
    expect(errors.single, startsWith('Malformed JSON'));
  });

  test('reports every failure at once', () {
    final errors = errorsOf(
      mutated((r) {
        r.remove('title');
        r['tags'] = 'bread';
      }),
    );
    expect(errors, hasLength(greaterThan(1)));
  });

  // A density outside culinary range is almost always an LLM emitting kg/m3
  // (530) rather than g/ml (0.53), which would render flour as a teaspoon.
  group('density', () {
    String withDensity(Object? value) => mutated(
      (r) => (r['ingredients'] as List)[0]['density_g_per_ml'] = value,
    );

    test('parses when present', () {
      expect(
        parser.parse(validJson).ingredientById('0001')!.densityGPerMl,
        0.53,
      );
    });

    test('is optional, both absent and explicitly null', () {
      final dropped = mutated(
        (r) => (r['ingredients'] as List)[0].remove('density_g_per_ml'),
      );
      expect(
        parser.parse(dropped).ingredientById('0001')!.densityGPerMl,
        isNull,
      );
      expect(
        parser.parse(withDensity(null)).ingredientById('0001')!.densityGPerMl,
        isNull,
      );
    });

    test('rejects a kg/m3 value', () {
      expect(errorsOf(withDensity(530)).join(), contains('density_g_per_ml'));
    });

    test('rejects zero and negatives', () {
      expect(errorsOf(withDensity(0)).join(), contains('density_g_per_ml'));
      expect(errorsOf(withDensity(-1)).join(), contains('density_g_per_ml'));
    });
  });

  /// The urls arrive from an LLM, which is told to give three even where it is
  /// unsure of any one of them — so this is a trust boundary, not a
  /// convenience. Three is a cap, not a target.
  group('image_urls', () {
    String withImages(Object? value) => mutated((r) => r['image_urls'] = value);

    test('is optional, and absent reads as none', () {
      final dropped = mutated((r) => r.remove('image_urls'));
      expect(parser.parse(dropped).imageUrls, isEmpty);
      expect(parser.parse(validJson).imageUrls, isEmpty);
    });

    test('keeps three in the order it was given', () {
      const urls = [
        'https://a.example/1.jpg',
        'https://b.example/2.jpg',
        'https://c.example/3.jpg',
      ];
      expect(parser.parse(withImages(urls)).imageUrls, urls);
    });

    test('rejects a fourth', () {
      final errors = errorsOf(
        withImages([
          'https://a.example/1.jpg',
          'https://b.example/2.jpg',
          'https://c.example/3.jpg',
          'https://d.example/4.jpg',
        ]),
      );
      expect(errors.join(), contains('image_urls'));
    });

    test("accepts the app's own scheme, for a photo off the device", () {
      expect(parser.parse(withImages(['mise://1724500000000.jpg'])).imageUrls, [
        'mise://1724500000000.jpg',
      ]);
    });

    test('rejects cleartext http, which phones refuse to load', () {
      expect(
        errorsOf(withImages(['http://example.com/a.jpg'])).join(),
        contains('image_urls'),
      );
    });

    test('rejects a bad entry even behind good ones', () {
      expect(
        errorsOf(
          withImages(['https://a.example/1.jpg', 'a photo of focaccia']),
        ).join(),
        contains('image_urls'),
      );
    });
  });
}
