import 'package:json_annotation/json_annotation.dart';

part 'recipe_models.g.dart';

/// Measurement units. `null` unit means a whole/countable item, where the
/// counting noun is folded into [Ingredient.name] (e.g. "garlic cloves").
enum Unit {
  g,
  kg,
  ml,
  l,
  tsp,
  tbsp,
  cup,
  @JsonValue('fl_oz')
  flOz,
  oz,
  lb,
  pinch,
}

@JsonSerializable(explicitToJson: true)
class Ingredient {
  /// 4-char id, e.g. '0001'. Referenced from [RecipeStep.content] as `{0001}`.
  final String id;
  final String name;
  final num amount;
  final Unit? unit;

  /// Grams per millilitre, when the ingredient is measurable both ways.
  /// Null is the norm for countable items and pinches, and means the amount
  /// can only ever read in the dimension it was written in.
  @JsonKey(name: 'density_g_per_ml')
  final num? densityGPerMl;

  const Ingredient({
    required this.id,
    required this.name,
    required this.amount,
    this.unit,
    this.densityGPerMl,
  });

  factory Ingredient.fromJson(Map<String, dynamic> json) =>
      _$IngredientFromJson(json);
  Map<String, dynamic> toJson() => _$IngredientToJson(this);
}

/// Named `RecipeStep` rather than `Step` to avoid colliding with
/// `material.Step` in widget files.
@JsonSerializable(fieldRename: FieldRename.snake, explicitToJson: true)
class RecipeStep {
  final String id;
  final String title;

  /// Ingredients are referenced inline as `{0001}` so amounts can be
  /// re-rendered when servings change.
  final String content;
  final int? timerSeconds;

  const RecipeStep({
    required this.id,
    required this.title,
    required this.content,
    this.timerSeconds,
  });

  factory RecipeStep.fromJson(Map<String, dynamic> json) =>
      _$RecipeStepFromJson(json);
  Map<String, dynamic> toJson() => _$RecipeStepToJson(this);
}

@JsonSerializable(fieldRename: FieldRename.snake, explicitToJson: true)
class Recipe {
  final String title;
  final int baseServings;
  final List<Ingredient> ingredients;
  final List<RecipeStep> steps;

  /// The headnote, shown above the ingredients rather than under the steps —
  /// where the dish comes from, when to make it, what can be swapped. The LLM
  /// writes it last, once it has the whole recipe in front of it, which is why
  /// it sits after [steps] in the schema: models emit an object in the order
  /// its properties are declared.
  final String? notes;

  /// Photos of the finished dish, best first — `https` urls the LLM found, or a
  /// single `mise://<filename>` pointing at a picked photo copied in beside the
  /// recipes.
  ///
  /// A list because a guessed url is often dead: the app shows the first that
  /// loads and treats the rest as fallbacks. Empty is the norm, and a recipe
  /// whose urls all fail reads as one with no photo at all. See
  /// `recipe_image.dart` for how a url becomes a picture.
  @JsonKey(defaultValue: <String>[])
  final List<String> imageUrls;
  final List<String> tags;
  final String source;
  final DateTime createdAt;

  const Recipe({
    required this.title,
    required this.baseServings,
    required this.ingredients,
    required this.steps,
    this.notes,
    this.imageUrls = const [],
    required this.tags,
    required this.source,
    required this.createdAt,
  });

  /// Recipes saved before the headnote replaced the separate `description`
  /// field carry both; fold the old one in rather than dropping it on the
  /// floor. This is the chokepoint for it because [RecipeStore] reads files
  /// straight through here without going past the validator — which is also
  /// why the schema could drop `description` outright: it never sees one.
  ///
  /// ponytail: delete once the recipes on this phone have each been saved.
  factory Recipe.fromJson(Map<String, dynamic> json) =>
      _$RecipeFromJson(_foldDescription(json));

  static Map<String, dynamic> _foldDescription(Map<String, dynamic> json) {
    final old = (json['description'] as String?)?.trim() ?? '';
    if (old.isEmpty) return json;
    final notes = (json['notes'] as String?)?.trim() ?? '';
    return {...json, 'notes': notes.isEmpty ? old : '$old\n\n$notes'};
  }
  Map<String, dynamic> toJson() => _$RecipeToJson(this);

  Ingredient? ingredientById(String id) =>
      ingredients.where((i) => i.id == id).firstOrNull;
}
