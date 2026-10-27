import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mise/recipe/recipe_parser.dart';

/// The phone and the server judge a recipe separately, and the server's
/// verdict is only worth something if it is the phone's. `server/tests/
/// test_validate.py` walks these same folders; a case added to one is a case
/// added to both. Each invalid file is named for the one thing wrong with it.
void main() {
  final parser = RecipeParser(File(recipeSchemaAsset).readAsStringSync());

  List<File> fixtures(String folder) =>
      Directory('test/fixtures/$folder').listSync().whereType<File>().toList()
        ..sort((a, b) => a.path.compareTo(b.path));

  for (final file in fixtures('valid')) {
    test('accepts ${file.uri.pathSegments.last}', () {
      expect(() => parser.parse(file.readAsStringSync()), returnsNormally);
    });
  }

  for (final file in fixtures('invalid')) {
    test('rejects ${file.uri.pathSegments.last}', () {
      expect(
        () => parser.parse(file.readAsStringSync()),
        throwsA(isA<RecipeValidationException>()),
      );
    });
  }
}
