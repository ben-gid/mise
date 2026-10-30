import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;

import 'recipe_models.dart';
import 'recipe_store.dart';

/// The photo on the tour's card, bundled so a first launch with no signal
/// still has one. An Unsplash photo, credited like any other.
const samplePhotoAsset = 'assets/samples/focaccia.jpg';
const _photoName = 'sample-focaccia.jpg';

/// The recipe the tour shows and a cook who writes nothing keeps. In code
/// rather than an asset so the tour has it on its first frame; trusted, so it
/// skips the validator, and `recipe_parser_test.dart` holds it to the schema.
/// A fixed `created_at` keeps its id fixed, so keeping it twice is one file.
final sampleRecipe = Recipe.fromJson(
  jsonDecode(r'''
{
  "title": "Garlic Butter Focaccia",
  "base_servings": 8,
  "makes": {"amount": 1, "one": "loaf", "other": "loaves"},
  "ingredients": [
    {"id": "0001", "name": "bread flour", "amount": 500, "unit": "g", "density_g_per_ml": 0.53},
    {"id": "0002", "name": "water", "amount": 400, "unit": "ml", "density_g_per_ml": 1.0},
    {"id": "0003", "name": "fine sea salt", "amount": 10, "unit": "g", "density_g_per_ml": 1.2},
    {"id": "0004", "name": "instant yeast", "amount": 1, "unit": "tsp"},
    {"id": "0005", "name": "garlic cloves", "amount": 4, "unit": null},
    {"id": "0006", "name": "butter", "amount": 60, "unit": "g", "density_g_per_ml": 0.91},
    {"id": "0007", "name": "flaky salt", "amount": 1, "unit": "pinch"}
  ],
  "steps": [
    {"id": "s1", "title": "Mix the dough", "content": "Whisk {0001}, {0003} and {0004}, then pour in {0002} and mix to a shaggy dough.", "timer_seconds": null},
    {"id": "s2", "title": "Bulk proof", "content": "Cover and leave at room temperature until doubled.", "timer_seconds": 7200},
    {"id": "s3", "title": "Make the garlic butter", "content": "Melt {0006} with finely sliced {0005} over low heat.", "timer_seconds": 300},
    {"id": "s4", "title": "Bake", "content": "Dimple the dough, pour over the garlic butter, scatter {0007} and bake at 220C.", "timer_seconds": 1500}
  ],
  "notes": "A slow-proofed focaccia with a garlic butter crust. The dough can sit overnight in the fridge instead of the two-hour proof, and is easier to dimple cold.",
  "image_query": "rustic focaccia bread",
  "image_urls": ["mise://sample-focaccia.jpg"],
  "image_credit": {"name": "Paula Berto", "url": "https://unsplash.com/@paulaberto?utm_source=mise&utm_medium=referral"},
  "tags": ["bread", "vegetarian", "make-ahead"],
  "source": "mise",
  "created_at": "2026-01-01T09:00:00Z"
}
''')
      as Map<String, dynamic>,
);

/// Saves what the tour ended on, copying the sample's photo in beside the
/// recipes first so its `mise://` url resolves.
Future<String> keepRecipe(RecipeStore store, Recipe recipe) async {
  if (identical(recipe, sampleRecipe)) {
    final photo = store.imageFile(_photoName);
    if (!photo.existsSync()) {
      final data = await rootBundle.load(samplePhotoAsset);
      await photo.writeAsBytes(data.buffer.asUint8List());
    }
  }
  return store.save(recipe);
}
